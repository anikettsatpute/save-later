import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Local reminder scheduling. Exact alarms need SCHEDULE_EXACT_ALARM on
/// Android 12+; we fall back to inexact when not granted.
class ReminderService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _init = false;

  static Future<void> init() async {
    if (_init) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    // Android 13+ needs runtime POST_NOTIFICATIONS — without this,
    // reminders silently never fire (mobile UX trap).
    try {
      await androidImpl?.requestNotificationsPermission();
    } catch (_) {}
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'reminders',
      'Reminders',
      description: 'Read-it-later reminders',
      importance: Importance.high,
    ));
    _init = true;
  }

  static Future<void> schedule({
    required int id,
    required String title,
    required DateTime when,
    String? body,
  }) async {
    await init();
    final android = AndroidNotificationDetails(
      'reminders',
      'Reminders',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: body != null ? BigTextStyleInformation(body) : null,
    );
    await _plugin.zonedSchedule(
      id,
      '⏰ $title',
      body ?? 'Time to revisit this saved item',
      tz.TZDateTime.from(when, tz.local),
      NotificationDetails(android: android),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  static Future<void> cancel(int id) async {
    await init();
    await _plugin.cancel(id);
  }

  /// Stable notification id from item id hash.
  static int notifId(String itemId) => itemId.hashCode & 0x7fffffff;
}
