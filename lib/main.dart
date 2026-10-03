/// Simple Financial Planner — balance, burn rate and runway, offline-first.
///
/// Home + History + Settings tabs, user-managed categories with keyword
/// auto-matching, a spend calendar, all persisted on-device in
/// SharedPreferences (keys under `simple_planner.*`, with read-fallback to
/// the legacy `vector.*` keys so existing installs migrate silently).
/// Cupertino-only, Liquid Glass throughout.
library;

import 'dart:async' show runZonedGuarded;
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // In release builds a widget whose build() throws is replaced by a blank
  // box that prints nothing, so the screen just goes white with no reason.
  // Surface it instead.
  ErrorWidget.builder = (FlutterErrorDetails d) => _CrashReport(d);
  // Build failures are caught above; async errors (a prefs read, a bad
  // decode) would otherwise escape silently, so the whole app runs guarded.
  runZonedGuarded(() {
    runApp(const SimplePlannerApp());
  }, (Object e, StackTrace s) {
    // ignore: avoid_print
    print('zone error: $e\n$s');
  });
}

class SimplePlannerApp extends StatelessWidget {
  const SimplePlannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'Simple Financial Planner',
      debugShowCheckedModeBanner: false,
      theme: const CupertinoThemeData(
        primaryColor: Color(0xFF6366F1),
        scaffoldBackgroundColor: Color(0xFFF5F5F7),
      ),
      // Clamp the system text scale: the big hero number and the money rows
      // run off the right edge at Android's larger font settings.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.8,
        maxScaleFactor: 1.2,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const HomePage(),
    );
  }
}

class AppColors {
  static const bgBase = Color(0xFFF5F5F7);
  static const bgGradientTop = Color(0xFFEEF1FF);
  static const bgGradientBottom = Color(0xFFF5F5F7);
  static const glassWhite = Color(0xCCFFFFFF);
  static const glassBorder = Color(0x33000000);
  static const accent = Color(0xFF6366F1);
  static const accentGradient = [Color(0xFF6366F1), Color(0xFF8B5CF6)];
  static const success = Color(0xFF10B981);
  static const successLight = Color(0xFFECFDF5);
  static const danger = Color(0xFFEF4444);
  static const dangerLight = Color(0xFFFEF2F2);
  static const warning = Color(0xFFF59E0B);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6B7280);
  static const textTertiary = Color(0xFF9CA3AF);
  static const textOnAccent = Color(0xFFFFFFFF);
}

/// Preset color palette for categories (user picks from these, no free hex input v1).
const List<int> kCategoryPalette = <int>[
  0xFFEF4444,
  0xFFF97316,
  0xFFF59E0B,
  0xFF10B981,
  0xFF14B8A6,
  0xFF3B82F6,
  0xFF6366F1,
  0xFF8B5CF6,
  0xFFEC4899,
  0xFF6B7280,
];

/// Preset Cupertino icon palette for categories. Keys are stored in
/// [Category.iconName]; the user picks manually from these.
const Map<String, IconData> kCategoryIcons = <String, IconData>{
  'cart': CupertinoIcons.cart_fill,
  'food': CupertinoIcons.shopping_cart,
  'car': CupertinoIcons.car_fill,
  'home': CupertinoIcons.house_fill,
  'plane': CupertinoIcons.airplane,
  'gift': CupertinoIcons.gift_fill,
  'health': CupertinoIcons.heart_fill,
  'book': CupertinoIcons.book_fill,
  'work': CupertinoIcons.briefcase_fill,
  'game': CupertinoIcons.gamecontroller_fill,
  'bag': CupertinoIcons.bag_fill,
  'tag': CupertinoIcons.tag_fill,
};

/// A user-managed expense category: display + budget + match keywords.
/// Seed list starts EMPTY (user supplies all names/keywords himself).
/// Expenses that match nothing fall in the implicit Uncategorized bucket
/// (null categoryId), which is NOT a stored category.
class Category {
  final String id;
  String name;
  int colorValue;
  String iconName;
  double budget;
  List<String> keywords;

  Category({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.iconName,
    required this.budget,
    List<String>? keywords,
  }) : keywords = keywords ?? <String>[];

  Color get color => Color(colorValue);

  IconData get icon => kCategoryIcons[iconName] ?? CupertinoIcons.tag_fill;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'color': colorValue,
        'icon': iconName,
        'budget': budget,
        'keywords': keywords,
      };

  static Category fromJson(Map<String, dynamic> j) {
    final kws = j['keywords'];
    return Category(
      id: (j['id'] as String?) ?? 'cat_${DateTime.now().microsecondsSinceEpoch}',
      name: (j['name'] as String?) ?? 'Category',
      colorValue: (j['color'] as num?)?.toInt() ?? 0xFF6366F1,
      iconName: (j['icon'] as String?) ?? 'tag',
      budget: (j['budget'] as num?)?.toDouble() ?? 0.0,
      keywords: kws is List
          ? kws.map((e) => e.toString()).toList()
          : <String>[],
    );
  }
}

/// Whole-word, case-insensitive match of [note] against category keywords.
/// Returns the matching category id, or null (Uncategorized).
/// Tie-break: longest matching keyword wins, then earliest category in list.
String? matchCategory(String note, List<Category> cats) {
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

/// Look up a category by id; null id (Uncategorized) or unknown id returns null.
Category? categoryById(List<Category> cats, String? id) {
  if (id == null) return null;
  for (final c in cats) {
    if (c.id == id) return c;
  }
  return null;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _balanceController = TextEditingController();
  final TextEditingController _dailyBudgetController = TextEditingController();
  final TextEditingController _expenseController = TextEditingController();
  final TextEditingController _expenseNoteController = TextEditingController();
  final TextEditingController _targetDateController = TextEditingController();

  double _currentBalance = 0;
  double _dailyBudget = 0;
  DateTime? _targetDate;
  final List<Map<String, dynamic>> _expenses = [];
  final List<Category> _categories = [];

  /// Set to true after initial SharedPreferences load completes.
  /// Prevents the initial setState calls (or first build) from
  /// overwriting saved data with defaults.
  bool _dataLoaded = false;

  // SharedPreferences keys (namespaced so we don't collide with anything else).
  static const _kBalance = 'vector.balance';
  static const _kDailyBudget = 'vector.daily_budget';
  static const _kTargetDateIso = 'vector.target_date_iso';
  static const _kExpensesJson = 'vector.expenses_json';
  static const _kCategoriesJson = 'vector.categories_json';

  /// Currently selected history filter: null = All, 'uncat' = Uncategorized, else category id.
  String? _historyFilter;

  /// Category currently expanded in the Settings editor (null = none).
  String? _editingCategoryId;

  /// Editor text controllers, keyed by category id. Created lazily so typed
  /// text survives setState rebuilds (e.g. tapping a color swatch).
  /// Entries are disposed + removed when their category is deleted.
  final Map<String, TextEditingController> _catNameCtrls = {};
  final Map<String, TextEditingController> _catBudgetCtrls = {};
  final Map<String, TextEditingController> _catKeywordsCtrls = {};

  @override
  void dispose() {
    _balanceController.dispose();
    _dailyBudgetController.dispose();
    _expenseController.dispose();
    _expenseNoteController.dispose();
    _targetDateController.dispose();
    for (final c in _catNameCtrls.values) {
      c.dispose();
    }
    for (final c in _catBudgetCtrls.values) {
      c.dispose();
    }
    for (final c in _catKeywordsCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Don't block initState on async work — schedule a microtask
    // and load from SharedPreferences. Until it completes we render
    // with defaults; once it does we call setState with the restored data.
    Future.microtask(_loadFromPrefs);
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loadedBalance = prefs.getDouble(_kBalance) ?? 0.0;
      final loadedDailyBudget = prefs.getDouble(_kDailyBudget) ?? 0.0;

      DateTime? loadedTargetDate;
      final targetIso = prefs.getString(_kTargetDateIso);
      if (targetIso != null && targetIso.isNotEmpty) {
        try {
          loadedTargetDate = DateTime.parse(targetIso);
        } catch (_) {
          loadedTargetDate = null;
        }
      }

      final loadedExpenses = <Map<String, dynamic>>[];
      final expensesJson = prefs.getString(_kExpensesJson);
      if (expensesJson != null && expensesJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(expensesJson);
          if (decoded is List) {
            for (final entry in decoded) {
              if (entry is Map) {
                final amount = (entry['amount'] as num?)?.toDouble();
                final note = entry['note'] as String? ?? 'Expense';
                final dateIso = entry['date_iso'] as String?;
                DateTime date;
                if (dateIso != null && dateIso.isNotEmpty) {
                  try {
                    date = DateTime.parse(dateIso);
                  } catch (_) {
                    date = DateTime.now();
                  }
                } else {
                  date = DateTime.now();
                }
                if (amount != null) {
                  loadedExpenses.add({
                    'amount': amount,
                    'note': note,
                    'date': date,
                    // Old saves lack this key; backfill runs after load.
                    'categoryId': entry['category_id'] as String?,
                  });
                }
              }
            }
          }
        } catch (_) {
          // Corrupted JSON — fall through with empty list.
        }
      }

      // Categories: seed EMPTY on first run (user supplies all names/keywords).
      final loadedCategories = <Category>[];
      final catsJson = prefs.getString(_kCategoriesJson);
      if (catsJson != null && catsJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(catsJson);
          if (decoded is List) {
            for (final entry in decoded) {
              if (entry is Map) {
                loadedCategories.add(
                    Category.fromJson(Map<String, dynamic>.from(entry)));
              }
            }
          }
        } catch (_) {
          // Corrupted JSON — fall through with empty list.
        }
      }

      if (!mounted) return;
      setState(() {
        _currentBalance = loadedBalance;
        _dailyBudget = loadedDailyBudget;
        _targetDate = loadedTargetDate;
        _expenses
          ..clear()
          ..addAll(loadedExpenses);
        _categories
          ..clear()
          ..addAll(loadedCategories);
        // Backfill: old expenses without a categoryId get matched now.
        // Pure function of (note, categories) — no data loss.
        for (final e in _expenses) {
          if (e['categoryId'] == null) {
            e['categoryId'] =
                matchCategory((e['note'] as String?) ?? '', _categories);
          }
        }
        if (_targetDate != null) {
          final d = _targetDate!;
          _targetDateController.text =
              '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        }
        _dataLoaded = true;
      });
    } catch (_) {
      // SharedPreferences failed to load (rare on Android). Keep defaults
      // and mark loaded so we don't accidentally overwrite saved data later.
      if (!mounted) return;
      setState(() {
        _dataLoaded = true;
      });
    }
  }

  Future<void> _saveBalance() async {
    if (!_dataLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBalance, _currentBalance);
    } catch (_) {
      // Silently ignore — persistence is best-effort.
    }
  }

  Future<void> _saveDailyBudget() async {
    if (!_dataLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kDailyBudget, _dailyBudget);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _saveTargetDate() async {
    if (!_dataLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_targetDate == null) {
        await prefs.remove(_kTargetDateIso);
      } else {
        await prefs.setString(_kTargetDateIso, _targetDate!.toIso8601String());
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _saveExpenses() async {
    if (!_dataLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        _expenses
            .map((e) => {
                  'amount': (e['amount'] as num).toDouble(),
                  'note': e['note'] as String? ?? 'Expense',
                  'date_iso': (e['date'] as DateTime).toIso8601String(),
                  'category_id': e['categoryId'] as String?,
                })
            .toList(),
      );
      await prefs.setString(_kExpensesJson, encoded);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _saveCategories() async {
    if (!_dataLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kCategoriesJson,
          jsonEncode(_categories.map((c) => c.toJson()).toList()));
    } catch (_) {
      // ignore
    }
  }

  double get _totalSpent =>
      _expenses.fold(0.0, (sum, e) => sum + (e['amount'] as double));
  double get _remaining => _currentBalance - _totalSpent;

  int get _daysUntilTarget {
    if (_targetDate == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(_targetDate!.year, _targetDate!.month, _targetDate!.day);
    final diff = target.difference(today).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Effective daily budget: user-set if available, else derived from balance / days.
  /// This is the FIXED daily target. We don't auto-adjust it.
  double get _effectiveDailyBudget {
    if (_dailyBudget > 0) return _dailyBudget;
    final days = _daysUntilTarget;
    if (days == 0 || _currentBalance == 0) return 0;
    return _currentBalance / days;
  }

  /// Total spent today (calendar day). Single source of truth for the
  /// hero third stat and the [_freeMoneyToday] fold below.
  double get _spentToday {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _expenses.fold<double>(0, (sum, e) {
      final d = e['date'] as DateTime;
      final dt = DateTime(d.year, d.month, d.day);
      return sum + (dt.isAtSameMomentAs(today) ? (e['amount'] as double) : 0);
    });
  }

  /// Free money for today = daily_budget - today's_spending.
  /// Only counts expenses that happened TODAY.
  /// If no target date, falls back to daily budget minus today's spend
  /// (the user-set daily is the budget for "today").
  double get _freeMoneyToday {
    if (_currentBalance == 0) return 0;
    final daily = _effectiveDailyBudget;
    if (daily == 0) {
      // No daily budget set: free money = remaining (don't show zeros)
      if (_remaining > 0) return _remaining;
      return 0;
    }
    return daily - _spentToday;
  }

  /// Projected end date: when money runs out based on current remaining
  /// and current avg daily spending. Pure math, no auto-adjustment.
  ///
  /// Algorithm:
  ///   1. If balance is 0, no plan — return null.
  ///   2. If already overspent, return today.
  ///   3. If no spend yet but daily_budget is set, project using daily_budget.
  ///   4. If no spend yet and no daily_budget, fall back to amortizing remaining
  ///      across `_daysUntilTarget` (target date).
  ///   5. If has spend, use a *capped* average: if user spent on N unique days,
  ///      avgDaily = totalSpent / N. But we also recognize that day-1's
  ///      one-time spend should not be projected as "every day" — we cap the
  ///      avg at the user's `_effectiveDailyBudget` if it would project too soon.
  DateTime? get _projectedEndDate {
    if (_currentBalance == 0) return null;
    if (_remaining <= 0) return DateTime.now();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // collect unique spend-days
    final spendDays = <String>{};
    for (final e in _expenses) {
      final d = e['date'] as DateTime;
      final dt = DateTime(d.year, d.month, d.day);
      spendDays.add(dt.toIso8601String());
    }
    final trackedDays = max(1, spendDays.length);

    // avg daily from observed spend
    final observedAvgDaily = _totalSpent / trackedDays;

    // user-set daily target, if any
    final userDaily = _effectiveDailyBudget;

    // If we have a user-set daily target, use the LARGER of (observed avg, daily target).
    // This prevents a one-time big purchase from projecting daily doom.
    double projectionRate;
    if (userDaily > 0) {
      projectionRate = observedAvgDaily > userDaily ? observedAvgDaily : userDaily;
    } else {
      projectionRate = observedAvgDaily;
    }

    // If we have no spend yet, project using the daily budget (or amortize).
    if (_totalSpent == 0) {
      if (userDaily > 0) {
        final days = (_remaining / userDaily).floor();
        return today.add(Duration(days: days));
      }
      // No daily budget, no spend, no projection possible
      return null;
    }

    if (projectionRate <= 0) return null;
    final daysLeft = (_remaining / projectionRate).floor();
    return today.add(Duration(days: daysLeft));
  }

  int get _daysLeftAtCurrentPace {
    final end = _projectedEndDate;
    if (end == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final e = DateTime(end.year, end.month, end.day);
    final diff = e.difference(today).inDays;
    return diff < 0 ? 0 : diff;
  }

  void _setBalance() {
    final value = ThousandsSeparatorInputFormatter.parse(_balanceController.text);
    if (value >= 0) {
      setState(() => _currentBalance = value);
      _saveBalance();
    }
  }

  void _setDailyBudget() {
    final value =
        ThousandsSeparatorInputFormatter.parse(_dailyBudgetController.text);
    if (value >= 0) {
      setState(() => _dailyBudget = value);
      _saveDailyBudget();
    }
  }

  void _setTargetDate(DateTime date) {
    setState(() {
      _targetDate = date;
      _targetDateController.text = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    });
    _saveTargetDate();
  }

  void _showDatePicker() {
    DateTime tempSelected = _targetDate ?? DateTime.now().add(const Duration(days: 30));
    showCupertinoModalPopup(
      context: context,
      builder: (context) => Container(
        height: 360,
        decoration: const BoxDecoration(
          color: Color(0xFFF5F5F7),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      child: const Text('Cancel',
                          style: TextStyle(color: AppColors.textSecondary)),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.bgBase,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.glassBorder, width: 0.5),
                      ),
                      child: const Text(
                        'Pick Date',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      child: const Text('Set',
                          style: TextStyle(
                              color: AppColors.accent, fontWeight: FontWeight.w700)),
                      onPressed: () {
                        _setTargetDate(tempSelected);
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.glassBorder, width: 0.5),
                  ),
                  child: CupertinoTheme(
                    data: const CupertinoThemeData(
                      brightness: Brightness.light,
                      textTheme: CupertinoTextThemeData(
                        dateTimePickerTextStyle: TextStyle(
                          fontSize: 20,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.date,
                      initialDateTime: tempSelected,
                      minimumDate: DateTime.now(),
                      backgroundColor: CupertinoColors.white,
                      onDateTimeChanged: (d) => tempSelected = d,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _addExpense() {
    final value = ThousandsSeparatorInputFormatter.parse(_expenseController.text);
    if (value > 0) {
      final note = _expenseNoteController.text.isEmpty
          ? 'Expense'
          : _expenseNoteController.text;
      setState(() {
        _expenses.insert(0, {
          'amount': value,
          'note': note,
          'date': DateTime.now(),
          'categoryId': matchCategory(note, _categories),
        });
        _expenseController.clear();
        _expenseNoteController.clear();
      });
      _saveExpenses();
    }
  }

  void _removeExpense(int index) {
    setState(() => _expenses.removeAt(index));
    _saveExpenses();
  }

  /// Total spent for one category over the whole plan period.
  /// Counts ALL expenses (locked decision) — no date filtering.
  /// Null id = the implicit Uncategorized bucket.
  double _spentForCategory(String? id) {
    return _expenses.fold<double>(0, (sum, e) {
      return sum +
          ((e['categoryId'] as String?) == id ? (e['amount'] as double) : 0);
    });
  }

  /// "Spending by category" card: horizontal spend-vs-budget bars in the
  /// category color. Hidden until the first category exists or there is
  /// uncategorized spend to show.
  Widget _buildCategorySpendCard() {
    final uncat = _spentForCategory(null);
    if (_categories.isEmpty && uncat == 0) return const SizedBox.shrink();
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(CupertinoIcons.chart_pie_fill,
                    color: AppColors.accent, size: 18),
              ),
              const SizedBox(width: 12),
              const Text(
                'Spending by category',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final c in _categories) ...[
            _categorySpendRow(
              color: c.color,
              icon: c.icon,
              name: c.name,
              spent: _spentForCategory(c.id),
              budget: c.budget,
            ),
            const SizedBox(height: 12),
          ],
          if (uncat > 0)
            _categorySpendRow(
              color: AppColors.textTertiary,
              icon: CupertinoIcons.tag_fill,
              name: 'Uncategorized',
              spent: uncat,
              budget: 0,
            ),
        ],
      ),
    );
  }

  Widget _categorySpendRow({
    required Color color,
    required IconData icon,
    required String name,
    required double spent,
    required double budget,
  }) {
    final ratio = budget > 0 ? (spent / budget).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 17),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    budget > 0
                        ? 'Rp ${_formatNumber(spent)} of Rp ${_formatNumber(budget)}'
                        : 'Rp ${_formatNumber(spent)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (budget > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 8,
              color: color.withOpacity(0.15),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ratio,
                  child: Container(color: color),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// "Budget left" card: per-category remaining (budget − spent over the
  /// whole plan period). Red when over. Only categories with a budget > 0
  /// appear here; the card hides when none have a budget.
  Widget _buildCategoryBudgetLeftCard() {
    final budgeted = _categories.where((c) => c.budget > 0).toList();
    if (budgeted.isEmpty) return const SizedBox.shrink();
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.success.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(CupertinoIcons.money_dollar_circle_fill,
                    color: AppColors.success, size: 18),
              ),
              const SizedBox(width: 12),
              const Text(
                'Budget left',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < budgeted.length; i++) ...[
            _budgetLeftRow(budgeted[i]),
            if (i < budgeted.length - 1)
              const SizedBox(
                  height: 1, child: ColoredBox(color: AppColors.glassBorder)),
          ],
        ],
      ),
    );
  }

  Widget _budgetLeftRow(Category c) {
    final left = c.budget - _spentForCategory(c.id);
    final over = left < 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(c.icon, color: c.color, size: 15),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c.name,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            over
                ? 'Rp ${_formatNumber(-left)} over'
                : 'Rp ${_formatNumber(left)} left',
            style: TextStyle(
              fontSize: 14,
              color: over ? AppColors.danger : AppColors.success,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
  // Calendar heatmap helpers

  double _spendingForDay(DateTime day) {
    final target = DateTime(day.year, day.month, day.day);
    return _expenses.fold<double>(0, (sum, e) {
      final d = e['date'] as DateTime;
      final dt = DateTime(d.year, d.month, d.day);
      return sum + (dt.isAtSameMomentAs(target) ? (e['amount'] as double) : 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Tab host: all three tabs read the same state object, so a spend
    // logged on Home is instantly reflected in History and Settings.
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.house_fill), label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.list_bullet), label: 'History'),
          BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.gear), label: 'Settings'),
        ],
      ),
      tabBuilder: (context, index) {
        return CupertinoTabView(
          builder: (context) {
            switch (index) {
              case 1:
                return _buildHistoryTab();
              case 2:
                return _buildSettingsTab();
              default:
                return _buildHomeTab();
            }
          },
        );
      },
    );
  }

  /// Shared gradient page wrapper used by all three tabs.
  Widget _tabPage({required List<Widget> children}) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.bgBase,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.bgGradientTop, AppColors.bgGradientBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: children,
          ),
        ),
      ),
    );
  }

  /// Home tab: the pre-tabs screen, unchanged (header, hero, input,
  /// plan setup, calendar, recent list).
  Widget _buildHomeTab() {
    return _tabPage(
      children: [
        _buildHeader(),
        const SizedBox(height: 20),
        // Prominent over-budget banner — sits ABOVE the hero card so
        // a user who is already in the red can't miss it. The hero
        // card still shows a duplicate, smaller status block too.
        if (_currentBalance > 0 && _remaining <= 0 && _targetDate != null)
          _buildOverBudgetBanner(),
        _buildHeroCard(),
        const SizedBox(height: 20),
        _buildExpenseInput(),
        const SizedBox(height: 20),
        _buildBudgetSetup(),
        const SizedBox(height: 20),
        _buildCalendar(),
        const SizedBox(height: 20),
        _buildCategorySpendCard(),
        const SizedBox(height: 20),
        _buildCategoryBudgetLeftCard(),
        const SizedBox(height: 24),
        _buildExpensesList(),
      ],
    );
  }

  /// History tab: all expenses, newest first, grouped under Today /
  /// Yesterday / date dividers, with an All + per-category filter chip row.
  /// Delete is long-press + confirm only (tap does nothing — no accidents).
  Widget _buildHistoryTab() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final filtered = _expenses.where((e) {
      if (_historyFilter == null) return true;
      if (_historyFilter == 'uncat') {
        return (e['categoryId'] as String?) == null;
      }
      return (e['categoryId'] as String?) == _historyFilter;
    }).toList()
      ..sort(
          (a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime));

    final groups = <DateTime, List<Map<String, dynamic>>>{};
    for (final e in filtered) {
      final d = e['date'] as DateTime;
      groups.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(e);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    String dividerLabel(DateTime day) {
      if (day.isAtSameMomentAs(today)) return 'Today';
      if (day.isAtSameMomentAs(yesterday)) return 'Yesterday';
      return '${day.day} ${_monthName(day.month).substring(0, 3)} ${day.year}';
    }

    return _tabPage(
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 8, bottom: 12),
          child: Text(
            'History',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: -0.6,
            ),
          ),
        ),
        _historyFilterChips(),
        const SizedBox(height: 16),
        if (filtered.isEmpty)
          const _GlassCard(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No expenses here yet',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          )
        else
          for (final day in days) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
              child: Text(
                dividerLabel(day),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            _GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (int i = 0; i < groups[day]!.length; i++) ...[
                    if (i > 0)
                      const SizedBox(
                          height: 1,
                          child:
                              ColoredBox(color: AppColors.glassBorder)),
                    _historyRow(groups[day]![i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        if (filtered.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Center(
              child: Text(
                'Long-press a row to delete it',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Filter chips: All + Uncategorized + one per category (colored dot).
  /// [_historyFilter]: null = All, 'uncat' = Uncategorized, else category id.
  Widget _historyFilterChips() {
    Widget chip({
      required String label,
      required bool selected,
      required Color dot,
      required String? value,
    }) {
      return GestureDetector(
        onTap: () => setState(() => _historyFilter = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : CupertinoColors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.glassBorder,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? AppColors.textOnAccent
                      : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip(
              label: 'All',
              selected: _historyFilter == null,
              dot: AppColors.accent,
              value: null),
          const SizedBox(width: 8),
          chip(
              label: 'Uncategorized',
              selected: _historyFilter == 'uncat',
              dot: AppColors.textTertiary,
              value: 'uncat'),
          for (final c in _categories) ...[
            const SizedBox(width: 8),
            chip(
                label: c.name,
                selected: _historyFilter == c.id,
                dot: c.color,
                value: c.id),
          ],
        ],
      ),
    );
  }

  /// One history row: category icon in a category-color rounded square,
  /// note + datetime + category spend-vs-budget, amount on the right.
  /// Long-press deletes (with confirm); tap does nothing.
  Widget _historyRow(Map<String, dynamic> expense) {
    final cat = categoryById(_categories, expense['categoryId'] as String?);
    final color = cat?.color ?? AppColors.textTertiary;
    final icon = cat?.icon ?? CupertinoIcons.tag_fill;
    final budget = cat?.budget ?? 0;
    final spent = _spentForCategory(cat?.id);
    final sub = cat == null
        ? 'Uncategorized · —'
        : (budget > 0
            ? '${cat.name} · Rp ${_formatNumber(spent)} of Rp ${_formatNumber(budget)}'
            : '${cat.name} · Rp ${_formatNumber(spent)}');

    return GestureDetector(
      onLongPress: () => _confirmDeleteExpense(expense),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        color: const Color(0x00000000),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (expense['note'] as String?) ?? 'Expense',
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatDateTime(expense['date'] as DateTime),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '−Rp ${_formatNumber(expense['amount'] as double)}',
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Safe-guarded delete: confirm dialog, then remove by identity
  /// (works on filtered/sorted views, not just list position).
  void _confirmDeleteExpense(Map<String, dynamic> expense) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete expense?'),
        content: Text(
          '${(expense['note'] as String?) ?? 'Expense'} · Rp ${_formatNumber(expense['amount'] as double)}',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _expenses.remove(expense));
              _saveExpenses();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Settings tab: the existing plan card moved unchanged, plus the
  /// category CRUD list + editor below it.
  Widget _buildSettingsTab() {
    return _tabPage(
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 8, bottom: 12),
          child: Text(
            'Settings',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: -0.6,
            ),
          ),
        ),
        _buildBudgetSetup(),
        const SizedBox(height: 20),
        _buildCategoryManager(),
      ],
    );
  }

  /// Category list + add button + per-category expand-to-edit editor.
  Widget _buildCategoryManager() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(CupertinoIcons.tag_fill,
                    color: AppColors.accent, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Categories (${_categories.length})',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.all(6),
                minSize: 0,
                onPressed: _addCategory,
                child: const Icon(CupertinoIcons.add_circled_solid,
                    color: AppColors.accent, size: 26),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_categories.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No categories yet. Tap + to add one — new spends auto-match on keywords.',
                style: TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
              ),
            )
          else
            for (int i = 0; i < _categories.length; i++) ...[
              if (i > 0)
                const SizedBox(
                    height: 1,
                    child: ColoredBox(color: AppColors.glassBorder)),
              _categoryEditorTile(_categories[i]),
            ],
        ],
      ),
    );
  }

  /// One category: summary row (tap to expand) + inline editor.
  Widget _categoryEditorTile(Category c) {
    final expanded = _editingCategoryId == c.id;
    final nameCtrl = _catNameCtrls.putIfAbsent(
        c.id, () => TextEditingController(text: c.name));
    final budgetCtrl = _catBudgetCtrls.putIfAbsent(c.id,
        () => TextEditingController(text: _formatNumber(c.budget)));
    final kwCtrl = _catKeywordsCtrls.putIfAbsent(
        c.id, () => TextEditingController(text: c.keywords.join(', ')));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => setState(
                () => _editingCategoryId = expanded ? null : c.id),
            child: Container(
              color: const Color(0x00000000),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(c.icon, color: c.color, size: 17),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name,
                          style: const TextStyle(
                            fontSize: 15,
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          c.budget > 0
                              ? 'Rp ${_formatNumber(c.budget)} · ${c.keywords.length} keyword${c.keywords.length == 1 ? '' : 's'}'
                              : 'No budget · ${c.keywords.length} keyword${c.keywords.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    expanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    color: AppColors.textTertiary,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 14),
            _GlassField(
              controller: nameCtrl,
              placeholder: 'Name',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 16, right: 8),
                child: Icon(CupertinoIcons.pencil,
                    color: AppColors.textTertiary, size: 16),
              ),
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Color',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final v in kCategoryPalette)
                  GestureDetector(
                    onTap: () {
                      setState(() => c.colorValue = v);
                      _saveCategories();
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(v),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c.colorValue == v
                              ? AppColors.textPrimary
                              : const Color(0x00000000),
                          width: 2,
                        ),
                      ),
                      child: c.colorValue == v
                          ? const Icon(CupertinoIcons.check_mark,
                              color: CupertinoColors.white, size: 16)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Icon',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in kCategoryIcons.entries)
                  GestureDetector(
                    onTap: () {
                      setState(() => c.iconName = entry.key);
                      _saveCategories();
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.iconName == entry.key
                            ? c.color.withOpacity(0.2)
                            : AppColors.bgBase.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: c.iconName == entry.key
                              ? c.color
                              : AppColors.glassBorder,
                          width: c.iconName == entry.key ? 1.5 : 0.5,
                        ),
                      ),
                      child: Icon(entry.value,
                          color: c.iconName == entry.key
                              ? c.color
                              : AppColors.textSecondary,
                          size: 18),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _GlassField(
              controller: budgetCtrl,
              placeholder: 'Budget (Rp)',
              keyboardType: TextInputType.number,
              inputFormatters: const [ThousandsSeparatorInputFormatter()],
              prefix: const Padding(
                padding: EdgeInsets.only(left: 16, right: 8),
                child: Text('Rp',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    )),
              ),
            ),
            const SizedBox(height: 10),
            _GlassField(
              controller: kwCtrl,
              placeholder: 'Keywords, comma separated (eat, lunch)',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 16, right: 8),
                child: Icon(CupertinoIcons.search,
                    color: AppColors.textTertiary, size: 16),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(12),
                    onPressed: () => _saveCategoryEdits(c),
                    child: const Text('Save',
                        style: TextStyle(
                            color: AppColors.textOnAccent,
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                  ),
                ),
                const SizedBox(width: 10),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                      vertical: 12, horizontal: 16),
                  color: AppColors.dangerLight,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: () => _confirmDeleteCategory(c),
                  child: const Text('Delete',
                      style: TextStyle(
                          color: AppColors.danger,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Add a category with a unique id; expand its editor immediately.
  void _addCategory() {
    final id = 'cat_${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _categories.add(Category(
        id: id,
        name: 'New category',
        colorValue: kCategoryPalette[_categories.length % kCategoryPalette.length],
        iconName: kCategoryIcons.keys
            .elementAt(_categories.length % kCategoryIcons.length),
        budget: 0,
      ));
      _editingCategoryId = id;
    });
    _saveCategories();
  }

  /// Commit editor field values into the category, then persist.
  void _saveCategoryEdits(Category c) {
    final name = (_catNameCtrls[c.id]?.text ?? '').trim();
    final budgetText = _catBudgetCtrls[c.id]?.text ?? '';
    final kwText = _catKeywordsCtrls[c.id]?.text ?? '';
    setState(() {
      if (name.isNotEmpty) c.name = name;
      c.budget = ThousandsSeparatorInputFormatter.parse(budgetText);
      c.keywords = kwText
          .split(',')
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty)
          .toList();
      _editingCategoryId = null;
    });
    _saveCategories();
  }

  /// Delete with confirm; its expenses re-tag to Uncategorized (null)
  /// in the same setState so nothing is orphaned. Persists both lists.
  void _confirmDeleteCategory(Category c) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete category?'),
        content: Text(
          '"${c.name}" will be removed. Its expenses become Uncategorized.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _categories.removeWhere((x) => x.id == c.id);
                for (final e in _expenses) {
                  if ((e['categoryId'] as String?) == c.id) {
                    e['categoryId'] = null;
                  }
                }
                if (_editingCategoryId == c.id) _editingCategoryId = null;
                _catNameCtrls.remove(c.id)?.dispose();
                _catBudgetCtrls.remove(c.id)?.dispose();
                _catKeywordsCtrls.remove(c.id)?.dispose();
              });
              _saveCategories();
              _saveExpenses();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final now = DateTime.now();
    final greeting = now.hour < 12
        ? 'Good morning'
        : now.hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            greeting,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textTertiary,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Where are you at?',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: -0.6,
            ),
          ),
        ],
      ),
    );
  }

  /// Status of the user's spending plan.
  /// - overBudgetNow: _remaining <= 0 (user is already in the red).
  /// - critical: positive remaining, but runway < 3 days at current pace.
  /// - overPace: positive remaining, projected end is before target.
  /// - noData: target set but no expenses logged yet (can't predict).
  /// - onTrack: positive remaining, projected end >= target, sufficient runway.
  /// - unset: no balance or no target (user hasn't set up a plan yet).
  String get _status {
    if (_currentBalance == 0) return 'unset';
    if (_remaining <= 0) return 'overBudgetNow';
    if (_expenses.isEmpty && _targetDate != null) return 'noData';
    final end = _projectedEndDate;
    if (end == null) return 'unset';
    if (_targetDate == null) {
      // No target: runway-based only.
      final runway = observedAvgDailySpending > 0
          ? _remaining / observedAvgDailySpending
          : 1e9;
      if (runway < 3) return 'critical';
      return 'onTrack';
    }
    // Has target. Three checks, in order of severity:
    // 1. Critical runway (regardless of end vs target)
    final dailyTarget = _effectiveDailyBudget;
    if (dailyTarget > 0 && (_remaining / dailyTarget) < 3) return 'critical';
    // 2. Will run out BEFORE target (overPace)
    final targetDay = DateTime(_targetDate!.year, _targetDate!.month, _targetDate!.day);
    final endDay = DateTime(end.year, end.month, end.day);
    if (endDay.isBefore(targetDay)) return 'overPace';
    // 3. Otherwise on track
    return 'onTrack';
  }

  /// Observed avg daily spend (read-only helper used by status and other getters).
  double get observedAvgDailySpending {
    if (_expenses.isEmpty) return 0;
    final spendDays = <String>{};
    for (final e in _expenses) {
      final d = e['date'] as DateTime;
      final dt = DateTime(d.year, d.month, d.day);
      spendDays.add(dt.toIso8601String());
    }
    if (spendDays.isEmpty) return 0;
    return _totalSpent / spendDays.length;
  }

  /// Days of money left at user-set daily target (not projected end).
  int get _runwayDays {
    if (_remaining <= 0) return 0;
    final daily = _effectiveDailyBudget;
    if (daily <= 0) return 0;
    return (_remaining / daily).floor();
  }

  /// Days the user will run out BEFORE their target date (positive = early).
  int get _daysEarlyVsTarget {
    if (_projectedEndDate == null || _targetDate == null) return 0;
    final end = _projectedEndDate!;
    final target = _targetDate!;
    final endDay = DateTime(end.year, end.month, end.day);
    final targetDay = DateTime(target.year, target.month, target.day);
    final diff = targetDay.difference(endDay).inDays;
    return diff > 0 ? diff : 0;
  }

  Widget _buildHeroCard() {
    final daysLeft = _daysUntilTarget;
    final dailyBudget = _effectiveDailyBudget;
    final freeToday = _freeMoneyToday;
    final endDate = _projectedEndDate;
    final status = _status;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: AppColors.accentGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withOpacity(0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: -50,
            right: -30,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.textOnAccent.withOpacity(0.1),
              ),
            ),
          ),
          Positioned(
            bottom: -40,
            left: -20,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.textOnAccent.withOpacity(0.06),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppColors.textOnAccent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            CupertinoIcons.creditcard_fill,
                            color: AppColors.textOnAccent,
                            size: 14,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Left in the pot',
                          style: TextStyle(
                            color: AppColors.textOnAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (daysLeft > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.textOnAccent.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '$daysLeft ${daysLeft == 1 ? 'day' : 'days'} to go',
                          style: const TextStyle(
                            color: AppColors.textOnAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Rp ${_formatNumber(_remaining)}',
                  style: const TextStyle(
                    color: AppColors.textOnAccent,
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.2,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.textOnAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.textOnAccent.withOpacity(0.2),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _heroStat(
                          'Each day',
                          dailyBudget > 0 ? 'Rp ${_formatNumber(dailyBudget)}' : '—',
                        ),
                      ),
                      Container(width: 1, height: 28, color: AppColors.textOnAccent.withOpacity(0.2)),
                      Expanded(
                        child: _heroStat(
                          'Today free',
                          freeToday > 0
                              ? 'Rp ${_formatNumber(freeToday)}'
                              : (dailyBudget == 0 ? '—' : '−Rp ${_formatNumber(-freeToday)}'),
                        ),
                      ),
                      Container(width: 1, height: 28, color: AppColors.textOnAccent.withOpacity(0.2)),
                      Expanded(
                        child: _heroStat(
                          'Today',
                          'Rp ${_formatNumber(_spentToday)}',
                        ),
                      ),
                    ],
                  ),
                ),
                // Status block: shows only when we have both a balance and a target.
                // Three distinct states — see _status getter.
                if (_targetDate != null && _currentBalance > 0) ...[
                  const SizedBox(height: 16),
                  _heroStatusBlock(status, endDate),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroStat(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textOnAccent.withOpacity(0.8),
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textOnAccent,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  /// Status block inside the hero card. Three distinct states with different
  /// icons, copy, and tints. overBudgetNow is rendered in a more prominent
  /// (danger/red) style so the user can't miss it.
  Widget _heroStatusBlock(String status, DateTime? endDate) {
    IconData icon;
    String title;
    String body;
    Color tint;
    Color iconBg;

    switch (status) {
      case 'overBudgetNow':
        icon = CupertinoIcons.exclamationmark_triangle_fill;
        title = "You're already over budget";
        body =
            'Currently −Rp ${_formatNumber(-_remaining)}. Time to cut spending or extend the date.';
        tint = AppColors.danger.withOpacity(0.95);
        iconBg = AppColors.textOnAccent.withOpacity(0.25);
        break;
      case 'critical':
        icon = CupertinoIcons.flame_fill;
        title = 'Only ${_runwayDays} day${_runwayDays == 1 ? '' : 's'} of runway left';
        body = _targetDate == null
            ? "At your current pace, you'll run out in ${_runwayDays} day${_runwayDays == 1 ? '' : 's'}."
            : "At your current pace, you'll run out ${_runwayDays} day${_runwayDays == 1 ? '' : 's'} before ${_shortDate(_targetDate!)}.";
        tint = AppColors.danger.withOpacity(0.85);
        iconBg = AppColors.textOnAccent.withOpacity(0.25);
        break;
      case 'overPace':
        icon = CupertinoIcons.exclamationmark_triangle_fill;
        // Salient number: how many days EARLY you'll run out, not absolute.
        final early = _daysEarlyVsTarget;
        if (early > 0) {
          title = "You'll run out $early day${early == 1 ? '' : 's'} early";
          body =
              "Money runs out around ${_shortDate(endDate!)} — that's $early day${early == 1 ? '' : 's'} before your ${_shortDate(_targetDate!)} plan. Adjust your plan?";
        } else {
          title = 'At this pace, money runs out ${_shortDate(endDate!)}';
          body =
              "That's ${_daysLeftAtCurrentPace} days from now vs your ${_daysUntilTarget}-day plan. What do you want to do?";
        }
        tint = AppColors.warning.withOpacity(0.95);
        iconBg = AppColors.textOnAccent.withOpacity(0.25);
        break;
      case 'noData':
        icon = CupertinoIcons.info_circle_fill;
        title = "Plan set — log your first expense";
        body =
            'You\'ve set ${_formatNumber(_currentBalance)} with target ${_shortDate(_targetDate!)}. Add a spend to see projections.';
        tint = AppColors.accent.withOpacity(0.6);
        iconBg = AppColors.textOnAccent.withOpacity(0.25);
        break;
      case 'unset':
        icon = CupertinoIcons.sparkles;
        title = 'Set a plan to start tracking';
        body = 'Add a balance and a target date above. I\'ll project when you\'ll run out.';
        tint = AppColors.accent.withOpacity(0.6);
        iconBg = AppColors.textOnAccent.withOpacity(0.25);
        break;
      default: // onTrack
        icon = CupertinoIcons.checkmark_seal_fill;
        title = _targetDate == null
            ? "You're on track"
            : "You'll make it to ${_shortDate(_targetDate!)}";
        body = _targetDate == null
            ? 'No target date set. Add one to get an end-date projection.'
            : 'Plenty of room. No changes needed.';
        tint = AppColors.success.withOpacity(0.95);
        iconBg = AppColors.textOnAccent.withOpacity(0.25);
        break;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.textOnAccent.withOpacity(0.25),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: AppColors.textOnAccent,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textOnAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    color: AppColors.textOnAccent.withOpacity(0.92),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Standalone, prominent over-budget banner shown above the hero card
  /// when the user is already in the red. Designed so it can't be missed:
  /// strong red background, white text, large icon.
  Widget _buildOverBudgetBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.danger.withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.textOnAccent.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              CupertinoIcons.exclamationmark_octagon_fill,
              color: AppColors.textOnAccent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "You're already over budget",
                  style: TextStyle(
                    color: AppColors.textOnAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Currently −Rp ${_formatNumber(-_remaining)}. Time to cut spending or extend the date.',
                  style: TextStyle(
                    color: AppColors.textOnAccent.withOpacity(0.92),
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBudgetSetup() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(CupertinoIcons.slider_horizontal_3,
                    color: AppColors.accent, size: 18),
              ),
              const SizedBox(width: 12),
              const Text(
                'Your plan',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Current Balance (with edit button)
          Row(
            children: [
              Expanded(
                child: _GlassField(
                  controller: _balanceController,
                  placeholder: 'Current balance',
                  keyboardType: TextInputType.number,
                  inputFormatters: const [ThousandsSeparatorInputFormatter()],
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 16, right: 8),
                    child: Text('Rp',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        )),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _AccentButton(
                label: 'Set',
                onPressed: _setBalance,
                width: 72,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Daily Budget (with edit button)
          Row(
            children: [
              Expanded(
                child: _GlassField(
                  controller: _dailyBudgetController,
                  placeholder: 'Daily budget (optional)',
                  keyboardType: TextInputType.number,
                  inputFormatters: const [ThousandsSeparatorInputFormatter()],
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 16, right: 8),
                    child: Text('Rp',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        )),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _AccentButton(
                label: 'Set',
                onPressed: _setDailyBudget,
                width: 72,
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _showDatePicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.bgBase.withOpacity(0.6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.glassBorder, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.calendar,
                    color: _targetDate == null ? AppColors.textTertiary : AppColors.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _targetDate == null
                          ? 'Pick the date you want to last until'
                          : 'Lasts until: ${_formatDate(_targetDate!)}',
                      style: TextStyle(
                        color: _targetDate == null
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Icon(CupertinoIcons.chevron_right,
                      color: AppColors.textTertiary, size: 16),
                ],
              ),
            ),
          ),
          if (_currentBalance > 0 && _daysUntilTarget > 0) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.bgBase.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.glassBorder, width: 0.5),
              ),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.info_circle,
                      color: AppColors.textSecondary, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _dailyBudget > 0
                          ? 'Daily target: Rp ${_formatNumber(_dailyBudget)}. You set it. We won\'t move it.'
                          : 'No daily target set. We\'ll use Rp ${_formatNumber(_effectiveDailyBudget)} a day from balance ÷ days.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCalendar() {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final firstWeekday = monthStart.weekday % 7; // 0 = Sunday
    final cells = <Widget>[];

    // Build 6 weeks * 7 days = 42 cells
    for (int i = 0; i < 42; i++) {
      final dayNum = i - firstWeekday + 1;
      if (dayNum < 1 || dayNum > daysInMonth) {
        cells.add(const SizedBox.shrink());
      } else {
        final date = DateTime(now.year, now.month, dayNum);
        cells.add(_calendarCell(date, dayNum));
      }
    }

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(CupertinoIcons.calendar_today,
                    color: AppColors.warning, size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                _monthName(now.month) + ' ${now.year}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Day labels
          Row(
            children: ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                .map((d) => Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: cells,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _legendDot(AppColors.success, 'Under'),
              const SizedBox(width: 16),
              _legendDot(AppColors.danger, 'Over'),
              const SizedBox(width: 16),
              _legendDot(AppColors.textTertiary, 'No spend'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withOpacity(0.6),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _calendarCell(DateTime date, int dayNum) {
    final spending = _spendingForDay(date);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isToday = date.isAtSameMomentAs(today);
    final isFuture = date.isAfter(today);
    final hasSpend = spending > 0;
    final dailyRef = _effectiveDailyBudget;

    Color bg;
    Color textColor;
    List<Shadow>? textShadows;
    if (!hasSpend) {
      bg = AppColors.bgBase.withOpacity(0.4);
      textColor = AppColors.textTertiary;
      textShadows = null;
    } else if (dailyRef > 0 && spending <= dailyRef) {
      final ratio = (spending / dailyRef).clamp(0.0, 1.0);
      bg = AppColors.success.withOpacity(0.3 + ratio * 0.4);
      // White text + dark halo so it stays readable on light green
      // AND on saturated dark green.
      textColor = CupertinoColors.white;
      textShadows = const [
        Shadow(color: Color(0xCC000000), blurRadius: 3, offset: Offset(0, 0)),
      ];
    } else {
      // Over budget (or no daily ref to compare against).
      final ratio = dailyRef > 0
          ? ((spending / dailyRef) - 1.0).clamp(0.0, 1.0)
          : 0.5;
      bg = AppColors.danger.withOpacity(0.4 + ratio * 0.4);
      // White text + stronger dark halo so it's readable on red.
      textColor = CupertinoColors.white;
      textShadows = const [
        Shadow(color: Color(0xDD000000), blurRadius: 4, offset: Offset(0, 0)),
        Shadow(color: Color(0xAA000000), blurRadius: 2, offset: Offset(0, 1)),
      ];
    }

    if (isFuture && !hasSpend) {
      textColor = AppColors.textTertiary;
      textShadows = null;
    }

    return GestureDetector(
      onTap: () {
        if (hasSpend) {
          showCupertinoModalPopup(
            context: context,
            builder: (context) => Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFFF5F5F7),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDate(date),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Spent: Rp ${_formatNumber(spending)}',
                      style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
                    ),
                    if (dailyRef > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        spending <= dailyRef
                            ? 'Under your daily goal of Rp ${_formatNumber(dailyRef)}'
                            : 'Over your daily goal of Rp ${_formatNumber(dailyRef)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: spending <= dailyRef
                              ? AppColors.success
                              : AppColors.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoButton(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Got it',
                            style: TextStyle(color: AppColors.textOnAccent)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      },
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: isToday
              ? Border.all(color: AppColors.accent, width: 1.5)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              dayNum.toString(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: hasSpend ? FontWeight.w800 : FontWeight.w500,
                color: textColor,
                shadows: textShadows,
              ),
            ),
            if (hasSpend)
              Text(
                'Rp${_shortNumber(spending)}',
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  shadows: textShadows,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpenseInput() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(CupertinoIcons.minus_circle_fill,
                    color: AppColors.danger, size: 18),
              ),
              const SizedBox(width: 12),
              const Text(
                'Log a spend',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _GlassField(
            controller: _expenseNoteController,
            placeholder: 'What was it?',
            prefix: const Padding(
              padding: EdgeInsets.only(left: 16, right: 8),
              child: Icon(CupertinoIcons.tag_solid, color: AppColors.textTertiary, size: 18),
            ),
          ),
          const SizedBox(height: 10),
          _GlassField(
            controller: _expenseController,
            placeholder: '0',
            keyboardType: TextInputType.number,
            inputFormatters: const [ThousandsSeparatorInputFormatter()],
            prefix: const Padding(
              padding: EdgeInsets.only(left: 16, right: 8),
              child: Text('Rp',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  )),
            ),
            suffix: _AccentButton(label: 'Add', onPressed: _addExpense, width: 72),
          ),
        ],
      ),
    );
  }

  Widget _buildExpensesList() {
    if (_expenses.isEmpty) {
      return _GlassCard(
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent.withOpacity(0.08),
              ),
              child: Icon(CupertinoIcons.tray_fill,
                  color: AppColors.accent.withOpacity(0.5), size: 28),
            ),
            const SizedBox(height: 12),
            const Text(
              'Nothing logged yet',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Add a spend above to see your month fill in',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return _GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(CupertinoIcons.list_bullet,
                      color: AppColors.warning, size: 18),
                ),
                const SizedBox(width: 12),
                Text(
                  'Recent (${_expenses.length})',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < _expenses.length; i++) ...[
            if (i > 0) const SizedBox(height: 1, child: ColoredBox(color: AppColors.glassBorder)),
            _expenseRow(_expenses[i], i),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _expenseRow(Map<String, dynamic> expense, int index) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      onPressed: () => _removeExpense(index),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.danger.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(CupertinoIcons.arrow_down,
                color: AppColors.danger, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  expense['note'],
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatDateTime(expense['date'] as DateTime),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '−Rp ${_formatNumber(expense['amount'] as double)}',
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(double n) {
    if (n < 0) return '−${_formatNumber(-n)}';
    final s = n.toInt().toString();
    final result = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) result.write('.');
      result.write(s[i]);
    }
    return result.toString();
  }

  String _shortNumber(double n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
    return n.toInt().toString();
  }

  String _formatDate(DateTime d) =>
      '${d.day}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _formatDateTime(DateTime d) =>
      '${_formatDate(d)} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _shortDate(DateTime d) =>
      '${_monthName(d.month).substring(0, 3)} ${d.day}';

  String _monthName(int m) {
    const names = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return names[m];
  }
}

class _AccentButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final double width;
  const _AccentButton({required this.label, required this.onPressed, this.width = 0});

  @override
  Widget build(BuildContext context) {
    final btn = CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      minSize: 0,
      onPressed: onPressed,
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(12),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textOnAccent,
          fontWeight: FontWeight.w700,
          fontSize: 15,
          letterSpacing: 0.2,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
      child: width > 0 ? SizedBox(width: width, child: btn) : btn,
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _GlassCard({required this.child, this.padding = const EdgeInsets.all(20)});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.glassWhite,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.glassBorder, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withOpacity(0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: const Color(0xFF000000).withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _GlassField extends StatelessWidget {
  final TextEditingController controller;
  final String placeholder;
  final TextInputType? keyboardType;
  final Widget? prefix;
  final Widget? suffix;
  final List<TextInputFormatter>? inputFormatters;
  const _GlassField({
    required this.controller,
    required this.placeholder,
    this.keyboardType,
    this.prefix,
    this.suffix,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgBase.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.glassBorder, width: 0.5),
      ),
      child: Row(
        children: [
          if (prefix != null) prefix!,
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              placeholder: placeholder,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              placeholderStyle: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 15,
              ),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              decoration: const BoxDecoration(),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 0),
            ),
          ),
          if (suffix != null) suffix!,
        ],
      ),
    );
  }
}

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

int max(int a, int b) => a > b ? a : b;

/// Formats a numeric text field with Indonesian-style thousand separators
/// (dots, e.g. "1.000.000") as the user types. Filters out anything but
/// digits so we never end up with stray commas or letters in the input.
///
/// Cursor behavior: always snaps to the end of the formatted text. This is
/// the simplest correct behavior for a numeric input — selection-based
/// positioning isn't worth the complexity here.
class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  const ThousandsSeparatorInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.isEmpty) {
      return const TextEditingValue();
    }
    final formatted = _withDots(digitsOnly);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  /// Strip dots and parse as a double. Callers should use this helper
  /// instead of `double.tryParse(controller.text)` directly so we get a
  /// clean number regardless of whether the formatter has run.
  static double parse(String text) {
    final cleaned = text.replaceAll('.', '').replaceAll(',', '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  static String _withDots(String digits) {
    final buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
}
