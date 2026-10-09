import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';

import 'en.dart';

/// Interface language. Ukrainian strings are the keys; English comes from [en].
///
/// `lang` is a plain global so that tr() works everywhere (also in model
/// code); background isolates get it through [inLang].
String lang = 'uk';

/// Bumped when the language changes; the app root rebuilds on it.
final langNotifier = ValueNotifier<String>('uk');

/// Forces a language regardless of settings (UI tests).
String? debugForceLang;

const supportedLangs = {'uk': 'Українська', 'en': 'English'};

/// 'auto' → Ukrainian for uk/ru/be phones, English otherwise.
String resolveLang(String setting) {
  final forced = debugForceLang;
  if (forced != null) return forced;
  if (setting == 'uk' || setting == 'en') return setting;
  final code = PlatformDispatcher.instance.locale.languageCode;
  return const {'uk', 'ru', 'be'}.contains(code) ? 'uk' : 'en';
}

void applyLang(String setting) {
  lang = resolveLang(setting);
  langNotifier.value = lang;
}

/// Translates a Ukrainian UI string.
String tr(String uk) {
  if (lang == 'uk') return uk;
  return en[uk] ?? uk;
}

/// Translates a template with {0}, {1}… placeholders and fills them in.
String trf(String uk, List<Object?> args) {
  var s = tr(uk);
  for (int i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}

/// Runs [f] with the given language set (for code running in an isolate).
T inLang<T>(String l, T Function() f) {
  lang = l;
  return f();
}
