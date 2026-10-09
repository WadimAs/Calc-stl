import '../data/records.dart';

class Client {
  final String id;
  final String name;
  final String phone;
  final String telegram; // @username or phone
  final String note;

  const Client({required this.id, required this.name, this.phone = '', this.telegram = '', this.note = ''});

  Client copyWith({String? name, String? phone, String? telegram, String? note}) => Client(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        telegram: telegram ?? this.telegram,
        note: note ?? this.note,
      );

  /// tel: link, or null without a phone.
  String? get callUrl {
    final p = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    return p.isEmpty ? null : 'tel:$p';
  }

  /// Telegram link from @username or phone.
  String? get telegramUrl {
    final t = telegram.trim();
    if (t.isNotEmpty) {
      final u = t.replaceAll('@', '').replaceAll('https://t.me/', '');
      if (RegExp(r'^\+?[0-9 ()-]{7,}$').hasMatch(u)) return 'https://t.me/+${u.replaceAll(RegExp(r'[^0-9]'), '')}';
      return 'https://t.me/$u';
    }
    final p = phone.replaceAll(RegExp(r'[^0-9]'), '');
    return p.isEmpty ? null : 'https://t.me/+$p';
  }

  String? get viberUrl {
    final p = phone.replaceAll(RegExp(r'[^0-9]'), '');
    return p.isEmpty ? null : 'viber://chat?number=%2B$p';
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'telegram': telegram, 'note': note};

  static Client? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    String s(String k) => raw[k] is String ? raw[k] as String : '';
    return Client(id: raw['id'] as String, name: s('name'), phone: s('phone'), telegram: s('telegram'), note: s('note'));
  }
}

const clientStore = RecordStore<Client>('clients.json', Client.fromJson, _clientJson, _clientId);
Map<String, dynamic> _clientJson(Client c) => c.toJson();
String _clientId(Client c) => c.id;
