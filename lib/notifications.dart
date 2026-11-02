import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Plant lokale Erinnerungen für die nächsten Tage (kein Server nötig).
/// Jeder Tag bekommt eine eigene Benachrichtigung, damit die von heute
/// entfallen kann, sobald schon etwas eingetragen wurde.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  static const _horizonDays = 14;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void> _queue = Future.value();

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _init() async {
    if (!supported || _ready) return;
    tzdata.initializeTimeZones();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    _ready = true;
  }

  /// Fragt die Berechtigung ab. Gibt true zurück, wenn Meldungen erlaubt sind.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    await _init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(
              alert: true, badge: false, sound: true) ??
          false;
    }
    return false;
  }

  /// Plant alles neu. Aufrufe laufen nacheinander, damit sie sich nicht
  /// gegenseitig in die Quere kommen.
  Future<void> sync({
    required bool enabled,
    required int hour,
    required int minute,
    required bool hasEntryToday,
  }) {
    _queue = _queue
        .then((_) => _sync(enabled, hour, minute, hasEntryToday))
        .catchError((Object e) {
      debugPrint('Erinnerungen konnten nicht geplant werden: $e');
    });
    return _queue;
  }

  Future<void> _sync(
      bool enabled, int hour, int minute, bool hasEntryToday) async {
    if (!supported) return;
    await _init();
    await _plugin.cancelAll();
    if (!enabled) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_reminder',
        'Tägliche Erinnerung',
        channelDescription: 'Erinnert dich ans Eintragen deiner Ziele',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final now = DateTime.now();
    for (var i = 0; i < _horizonDays; i++) {
      final when = DateTime(now.year, now.month, now.day + i, hour, minute);
      if (!when.isAfter(now)) continue; // Uhrzeit heute schon vorbei
      if (i == 0 && hasEntryToday) continue; // heute schon eingetragen
      final id = when.year * 10000 + when.month * 100 + when.day;
      await _plugin.zonedSchedule(
        id,
        'Zielpunkte',
        'Hast du heute schon deine Ziele eingetragen?',
        // Einmalige Benachrichtigung zu einem festen Zeitpunkt (UTC-Instant).
        tz.TZDateTime.from(when, tz.UTC),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }
}
