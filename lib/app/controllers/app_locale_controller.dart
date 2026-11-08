import 'package:flashbyte/app/app_settings.dart';
import 'package:flutter/material.dart';

/// 管理应用语言设置，支持跟随系统、简体中文、英文。
class AppLocaleController extends ChangeNotifier {
  AppLocaleController._();

  static final AppLocaleController instance = AppLocaleController._();

  String _languageCode = AppSettings.defaultLanguageCode;
  Locale? _locale;

  String get languageCode => _languageCode;

  /// 为 null 时表示跟随系统。
  Locale? get locale => _locale;

  Future<void> load() async {
    _languageCode = await AppSettings.getLanguage();
    _updateLocale();
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    if (_languageCode == code) {
      return;
    }
    _languageCode = code;
    await AppSettings.setLanguage(code);
    _updateLocale();
    notifyListeners();
  }

  void _updateLocale() {
    switch (_languageCode) {
      case 'zh':
        _locale = const Locale('zh');
        break;
      case 'en':
        _locale = const Locale('en');
        break;
      default:
        _locale = null;
    }
  }
}
