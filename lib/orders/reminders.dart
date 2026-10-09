import '../platform/files.dart';
import 'orders.dart';

/// Deadline notifications: 09:00 on the due date while the order is not printed.
class OrderReminders {
  static DateTime? fireTime(Order o, {DateTime? now}) {
    final d = o.dueAt;
    if (d == null || o.status.printed) return null;
    final at = DateTime(d.year, d.month, d.day, 9);
    return at.isAfter(now ?? DateTime.now()) ? at : null;
  }

  static Future<void> sync(Order o) async {
    await PlatformFiles.cancelReminder(o.reminderId);
    final at = fireTime(o);
    if (at == null) return;
    final t = o.totals;
    await PlatformFiles.scheduleReminder(
      o.reminderId,
      at,
      'Сьогодні термін: ${o.title}',
      '${t.pieces} шт · ${o.status.label}${o.note.trim().isEmpty ? '' : ' · ${o.note.trim()}'}',
    );
  }

  static Future<void> cancel(Order o) => PlatformFiles.cancelReminder(o.reminderId);

  /// Alarms are lost on reboot, so they are set again on every app start.
  static Future<void> rescheduleAll() async {
    final list = await OrderStore.load();
    for (final o in list) {
      if (fireTime(o) != null) await sync(o);
    }
  }
}
