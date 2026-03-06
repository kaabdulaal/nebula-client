import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../main.dart';
import '../permissions/nebula_permissions.dart';

abstract final class NebulaForegroundService {
  NebulaForegroundService._();

  static Future<bool> start({
    required String title,
    required String content,
  }) async {
    if (!Platform.isAndroid) return true;

    final hasPermission = await NebulaPermissions.requestNotifications();
    if (!hasPermission) return false;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nebula_sync_channel',
        channelName: 'Nebula Sync Service',
        channelDescription: 'Shows file synchronization progress',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    final bool result = await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: content,
      callback: startCallback,
    );

    return result;
  }

  static Future<bool> stop() async {
    if (!Platform.isAndroid) return true;
    final bool result = await FlutterForegroundTask.stopService();
    return result;
  }

  static Future<void> updateNotification({
    required String title,
    required String content,
  }) async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: content,
    );
  }
}
