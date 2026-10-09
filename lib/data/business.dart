import 'json_store.dart';

/// Seller details printed on invoices.
class BusinessInfo {
  final String name; // ФОП / studio name
  final String contacts; // phone, Telegram, site
  final String payment; // IBAN / card / how to pay

  const BusinessInfo({this.name = '', this.contacts = '', this.payment = ''});

  bool get isEmpty => name.trim().isEmpty && contacts.trim().isEmpty && payment.trim().isEmpty;

  Map<String, dynamic> toJson() => {'name': name, 'contacts': contacts, 'payment': payment};

  static BusinessInfo fromJson(Object? raw) {
    if (raw is! Map) return const BusinessInfo();
    String s(String k) => raw[k] is String ? raw[k] as String : '';
    return BusinessInfo(name: s('name'), contacts: s('contacts'), payment: s('payment'));
  }

  static const file = 'business.json';

  static Future<BusinessInfo> load() async => fromJson(await JsonStore.read(file));

  Future<void> save() => JsonStore.write(file, toJson());
}
