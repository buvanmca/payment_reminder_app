import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A supported display currency. Only the **symbol and digit grouping** change
/// with the selection — amounts are never converted (a ₹1,500 plan shown as
/// USD displays $1,500, not an FX-converted value).
class Currency {
  const Currency({
    required this.code,
    required this.symbol,
    required this.locale,
    required this.label,
  });

  final String code; // ISO 4217, e.g. 'USD'
  final String symbol; // e.g. '$'
  final String locale; // controls digit grouping, e.g. 'en_US' / 'en_IN'
  final String label; // UI label, e.g. 'US Dollar ($)'

  NumberFormat get format =>
      NumberFormat.currency(locale: locale, symbol: symbol, decimalDigits: 0);

  /// Grouped number WITHOUT the symbol, e.g. '1,500' (or lakh-style for INR).
  String number(num v) => NumberFormat.decimalPattern(locale).format(v);
}

/// The currencies offered in Settings. INR is first so it remains the default
/// (preserving the app's original behavior); add entries here to support more.
const List<Currency> kSupportedCurrencies = [
  Currency(code: 'INR', symbol: '₹', locale: 'en_IN', label: 'Indian Rupee (₹)'),
  Currency(code: 'USD', symbol: '\$', locale: 'en_US', label: 'US Dollar (\$)'),
  Currency(code: 'EUR', symbol: '€', locale: 'en_IE', label: 'Euro (€)'),
  Currency(code: 'GBP', symbol: '£', locale: 'en_GB', label: 'British Pound (£)'),
  Currency(code: 'AED', symbol: 'AED ', locale: 'en_AE', label: 'UAE Dirham (AED)'),
];

final Currency kDefaultCurrency = kSupportedCurrencies[0]; // INR

Currency currencyByCode(String? code) => kSupportedCurrencies.firstWhere(
      (c) => c.code == code,
      orElse: () => kDefaultCurrency,
    );

/// Synchronously-readable current currency, loaded once at startup (see
/// `main.dart`). Kept static so pure helpers (e.g. message templates) and
/// widgets can format money without threading a provider through every call.
class CurrencyConfig {
  CurrencyConfig._();

  static const _prefsKey = 'currency_code_v1';
  static Currency _current = kDefaultCurrency;

  static Currency get current => _current;

  /// Currency formatter (symbol + grouping), e.g. `CurrencyConfig.money.format(1500)`.
  static NumberFormat get money => _current.format;
  static String get symbol => _current.symbol;
  static String number(num v) => _current.number(v);

  /// Call once during app startup, before the first money is rendered.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _current = currencyByCode(prefs.getString(_prefsKey));
  }

  static Future<void> save(Currency c) async {
    _current = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, c.code);
  }
}

/// Reactive handle for the Settings picker. Setting it persists the choice and
/// updates [CurrencyConfig] so subsequent formatting (including messages) uses
/// the new currency.
class CurrencyController extends StateNotifier<Currency> {
  CurrencyController() : super(CurrencyConfig.current);

  Future<void> set(Currency c) async {
    await CurrencyConfig.save(c);
    state = c;
  }
}

final currencyProvider =
    StateNotifierProvider<CurrencyController, Currency>((_) => CurrencyController());
