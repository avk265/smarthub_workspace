import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class PushNotificationService {
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final String apiUrl = 'http://localhost:8000/api/v1'; // Change for production

  Future<void> initialize(String userJwtToken) async {
    // 1. Request Permission (Required for iOS, Android 13+, and Web)
    NotificationSettings settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      print('User granted permission');
      
      // 2. Get the unique Device Token for this specific phone
      String? deviceToken = await _fcm.getToken();
      
      if (deviceToken != null) {
        print("Firebase Device Token: $deviceToken");
        // 3. Send this token to your FastAPI backend to save in the DB
        await _sendTokenToBackend(deviceToken, userJwtToken);
      }

      // 4. Listen for token refreshes
      _fcm.onTokenRefresh.listen((newToken) {
        _sendTokenToBackend(newToken, userJwtToken);
      });

      // 5. Handle messages while the app is actively open on the screen
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('Got a message whilst in the foreground!');
        if (message.notification != null) {
          print('Message also contained a notification: ${message.notification}');
        }
      });
      
    } else {
      print('User declined or has not accepted permission');
    }
  }

  // --- Send Token to your Python API ---
  Future<void> _sendTokenToBackend(String deviceToken, String jwtToken) async {
    try {
      await http.post(
        Uri.parse('$apiUrl/auth/device-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwtToken',
        },
        body: json.encode({'token': deviceToken}),
      );
      print("Token successfully synced with Python backend.");
    } catch (e) {
      print("Failed to sync token with backend: $e");
    }
  }
}