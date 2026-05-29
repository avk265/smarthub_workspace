import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'user_management_screen.dart';
import 'queue_dashboard.dart';
import 'profile_screen.dart';
import 'auth_screen.dart';
import 'todo_screen.dart';
import 'notification_screen.dart';
import 'chat_screen.dart';
import 'document_screen.dart';
import '../services/push_notification_service.dart';

class MainLayout extends StatefulWidget {
  final String token;
  const MainLayout({super.key, required this.token});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  // Default to Profile Screen (Index 2) to ensure non-admins don't default to an admin screen
  int _currentIndex = 2; 
  bool isAdmin = false;
  bool isLoadingRole = true;

  @override
  void initState() {
    super.initState();
    PushNotificationService().initialize(widget.token);
    _checkUserRole();
  }

  Future<void> _checkUserRole() async {
    try {
      final response = await http.get(
        Uri.parse('http://localhost:8000/api/v1/auth/profile'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          isAdmin = data['is_admin'] ?? false;
          isLoadingRole = false;
        });
      } else {
        setState(() => isLoadingRole = false);
      }
    } catch (e) {
      setState(() => isLoadingRole = false);
    }
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Get the FCM token if we stored it locally during login
    final String? fcmToken = prefs.getString('fcm_device_token'); 

    // 2. Ping the backend to announce the logout and kill push notifications
    try {
      await http.post(
        Uri.parse('http://localhost:8000/api/v1/auth/logout'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: json.encode({
          'fcm_token': fcmToken 
        }),
      );
    } catch (e) {
      debugPrint("Backend ping failed, but proceeding with local logout: $e");
    }

    // 3. Wipe local memory
    await prefs.remove('jwt_token');
    
    // 4. Return to Auth Screen
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const AuthScreen()),
        (route) => false, 
      );
    }
  }

  // FIXED: Changed from a static list to a getter (=>) so it dynamically 
  // updates the NotificationsScreen whenever `isAdmin` changes.
  List<Widget> get _screens => [
    UserManagementScreen(token: widget.token, onUnauthorized: _logout), // Index 0 (Admin Only)
    QueueDashboard(token: widget.token, onUnauthorized: _logout),       // Index 1 (Admin Only)
    ProfileScreen(token: widget.token, onUnauthorized: _logout),        // Index 2
    ChatScreen(token: widget.token, onUnauthorized: _logout),           // Index 3
    DocumentScreen(token: widget.token, onUnauthorized: _logout),       // Index 4 
    TodoScreen(token: widget.token, onUnauthorized: _logout),           // Index 5
    NotificationsScreen(
      token: widget.token,
      isAdmin: isAdmin,         // FIXED: Passed the correct variable name
      onUnauthorized: _logout,  // FIXED: Passed the correct function name
    ), // Index 6
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SmartHub', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Color(0xFF0F172A)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.hub, color: Colors.white, size: 40),
                  SizedBox(height: 12),
                  Text('SmartHub Workspace', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            
            _buildDrawerItem(Icons.person, 'My Profile', 2),
            
            // --- STRICT ROLE-BASED RENDERING ---
            if (isLoadingRole) 
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (isAdmin) ...[ // FIXED: Added Dart spread operator ...[] for multiple widgets
              _buildDrawerItem(Icons.people_alt_outlined, 'User Management', 0),
              _buildDrawerItem(Icons.queue, 'Notification Queue (Admin)', 1),
            ],
            // -----------------------------------
            
            const Divider(),
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 8, bottom: 8),
              child: Text("TOOLS", style: TextStyle( fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black38)),
            ),
            _buildDrawerItem(Icons.chat_bubble_outline, 'SmartHub AI', 3), 
            _buildDrawerItem(Icons.folder_shared_outlined, 'My Documents', 4),
            const Divider(),
            
            _buildDrawerItem(Icons.check_box_outlined, 'Todos', 5),
            _buildDrawerItem(Icons.notifications_outlined, 'My Inbox', 6), 
            
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: const Text('Secure Logout', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w500)),
              onTap: _logout,
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
    );
  }

  Widget _buildDrawerItem(IconData icon, String title, int index) {
    final isSelected = _currentIndex == index;
    return ListTile(
      leading: Icon(icon, color: isSelected ? const Color(0xFF0F172A) : Colors.black54),
      title: Text(
        title, 
        style: TextStyle(
          color: isSelected ? const Color(0xFF0F172A) : Colors.black87,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal
        )
      ),
      selected: isSelected,
      selectedTileColor: Colors.grey[100],
      onTap: () {
        setState(() => _currentIndex = index);
        Navigator.pop(context); // Close drawer
      },
    );
  }
}