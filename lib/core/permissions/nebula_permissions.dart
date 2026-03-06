import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

abstract final class NebulaPermissions {
  NebulaPermissions._();

  static Future<bool> requestNotifications() async {
    if (!Platform.isAndroid) return true;

    final status = await Permission.notification.request();
    return _isGranted(status);
  }

  static Future<bool> checkNotifications() async {
    if (!Platform.isAndroid) return true;
    return await Permission.notification.isGranted;
  }

  static Future<bool> openSettings() => openAppSettings();

  static bool _isGranted(PermissionStatus s) =>
      s == PermissionStatus.granted || s == PermissionStatus.limited;
}
