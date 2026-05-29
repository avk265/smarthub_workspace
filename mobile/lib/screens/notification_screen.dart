import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class NotificationsScreen extends StatefulWidget {
  final String token;
  final bool isAdmin; // <-- 1. Add this variable
  final VoidCallback onUnauthorized;

  const NotificationsScreen({
    super.key, 
    required this.token, 
    required this.isAdmin, // <-- Require it in the constructor
    required this.onUnauthorized
  });
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool isLoading = true;
  List<dynamic> notifications = [];
  final String apiUrl = 'http://localhost:8000/api/v1';

  @override
  void initState() {
    super.initState();
    _fetchUserNotifications();
  }

  // --- UPGRADED: FETCH REAL DATABASE INBOX ---
  Future<void> _fetchUserNotifications() async {
    try {
      final response = await http.get(
        Uri.parse('$apiUrl/notifications/inbox'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
        },
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (mounted) {
          setState(() {
            // Map the backend DB fields to the UI fields
            notifications = data.map((item) {
              return {
                "id": item["id"].toString(),
                "type": "system", // Defaulting to system icon for admin pushes
                "title": item["title"] ?? "SmartHub Alert",
                "message": item["message"] ?? "",
                "is_read": item["is_read"] ?? false,
                "time": _formatDate(item["created_at"]),
              };
            }).toList();
            isLoading = false;
          });
        }
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      } else {
        if (mounted) setState(() => isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      print("Error fetching inbox: $e");
    }
  }

  // Helper to format backend ISO strings to readable time
  String _formatDate(String? isoString) {
    if (isoString == null) return "Just now";
    try {
      final DateTime date = DateTime.parse(isoString).toLocal();
      final DateTime now = DateTime.now();
      final Duration diff = now.difference(date);
      
      if (diff.inMinutes < 1) return "Just now";
      if (diff.inHours < 1) return "${diff.inMinutes}m ago";
      if (diff.inDays < 1) return "${diff.inHours}h ago";
      if (diff.inDays < 7) return "${diff.inDays}d ago";
      return "${date.month}/${date.day}/${date.year}";
    } catch (e) {
      return "Recently";
    }
  }

  // --- UPGRADED: MARK SINGLE ITEM AS READ IN DB ---
  Future<void> _markAsRead(String id, int index) async {
    if (notifications[index]['is_read']) return; // Already read

    // 1. Optimistic UI update (feels instantly responsive)
    setState(() {
      notifications[index]['is_read'] = true;
    });

    // 2. Background sync to Database
    try {
      await http.put(
        Uri.parse('$apiUrl/notifications/inbox/$id/read'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
    } catch (e) {
      print("Failed to sync read status: $e");
      // Optionally revert UI if it fails
    }
  }

  void _markAllAsRead() {
    setState(() {
      for (var notif in notifications) {
        notif['is_read'] = true;
      }
    });
    // For a production app, you would add a "mark all read" endpoint to your backend too
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All notifications marked as read locally.')),
    );
  }

  void _showComposeMessageSheet() {
    final TextEditingController recipientController = TextEditingController();
    final TextEditingController messageController = TextEditingController();
    bool isSending = false;
    String selectedChannel = 'push'; // Default to push now

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            bool isPhone = selectedChannel == 'sms' || selectedChannel == 'whatsapp';
            String hintText = isPhone ? "+1 (555) 123-4567" : "student@example.com";
            IconData prefixIcon = isPhone ? Icons.phone_android : Icons.alternate_email;
            
            // If Push is selected, we don't need a specific recipient because our Admin Push targets EVERYONE
            bool isBulkPush = selectedChannel == 'push';

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 24, right: 24, top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Send Notification', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  const SizedBox(height: 16),
                  
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'push', label: Text('App Push'), icon: Icon(Icons.notifications_active)),
                      ButtonSegment(value: 'email', label: Text('Email'), icon: Icon(Icons.email_outlined)),
                    ],
                    selected: {selectedChannel},
                    onSelectionChanged: (Set<String> newSelection) {
                      setModalState(() {
                        selectedChannel = newSelection.first;
                        recipientController.clear();
                      });
                    },
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith<Color>(
                        (Set<WidgetState> states) {
                          if (states.contains(WidgetState.selected)) {
                            return Colors.blue.shade100;
                          }
                          return Colors.transparent;
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  if (!isBulkPush) ...[
                    TextField(
                      controller: recipientController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'Recipient Email',
                        hintText: hintText,
                        prefixIcon: Icon(prefixIcon),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  
                  TextField(
                    controller: messageController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: isBulkPush ? 'Broadcast Message...' : 'Message content...',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFF0F172A),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: isSending ? null : () async {
                      if ((!isBulkPush && recipientController.text.isEmpty) || messageController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
                        return;
                      }
                      
                      setModalState(() => isSending = true);

                      try {
                        // Choose between the single send or the admin bulk push endpoint
                        final url = isBulkPush 
                            ? '$apiUrl/notify/bulk/push' 
                            : '$apiUrl/notify/send';
                            
                        final body = isBulkPush 
                            ? {'title': 'Admin Broadcast', 'message': messageController.text.trim()}
                            : {'channel': selectedChannel, 'recipient': recipientController.text.trim(), 'message': messageController.text.trim()};

                        final response = await http.post(
                          Uri.parse(url),
                          headers: {
                            'Content-Type': 'application/json',
                            'Authorization': 'Bearer ${widget.token}',
                          },
                          body: json.encode(body),
                        );

                        if (response.statusCode == 200 || response.statusCode == 202) {
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Successfully dispatched via ${selectedChannel.toUpperCase()}!'), backgroundColor: Colors.green));
                            
                            // Refresh inbox to see our own broadcast
                            if (isBulkPush) _fetchUserNotifications(); 
                          }
                        } else if (response.statusCode == 401 || response.statusCode == 403) {
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Admin privileges required.'), backgroundColor: Colors.red));
                        } else {
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to dispatch.'), backgroundColor: Colors.red));
                        }
                      } catch (e) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Network error.'), backgroundColor: Colors.red));
                      } finally {
                        setModalState(() => isSending = false);
                      }
                    },
                    child: isSending 
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(isBulkPush ? 'BROADCAST TO ALL USERS' : 'SEND DIRECT MESSAGE', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          }
        );
      },
    );
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'chat': return Icons.chat_bubble_outline;
      case 'todo': return Icons.check_box_outlined;
      case 'system': return Icons.security_outlined;
      default: return Icons.notifications_none;
    }
  }

  Color _getColorForType(String type) {
    switch (type) {
      case 'chat': return Colors.blueAccent;
      case 'todo': return Colors.green.shade600;
      case 'system': return Colors.orange.shade700;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('My Inbox', style: TextStyle(fontSize: 18)),
        actions: [
          TextButton(
            onPressed: _markAllAsRead,
            child: const Text("Mark All Read", style: TextStyle(color: Colors.blueAccent)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0F172A)))
          : notifications.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.notifications_off_outlined, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text("No new notifications.", style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: notifications.length,
                  itemBuilder: (context, index) {
                    final notif = notifications[index];
                    final bool isRead = notif['is_read'];
                    
                    // Wrapped Card in a GestureDetector to trigger _markAsRead
                    return GestureDetector(
                      onTap: () => _markAsRead(notif['id'], index),
                      child: Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: isRead ? Colors.transparent : Colors.blue.shade100, width: 1.5),
                        ),
                        color: isRead ? Colors.white : Colors.blue.shade50.withOpacity(0.3),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: _getColorForType(notif['type']).withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  _getIconForType(notif['type']), 
                                  color: _getColorForType(notif['type']),
                                  size: 24
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          notif['title'], 
                                          style: TextStyle(
                                            fontWeight: isRead ? FontWeight.w600 : FontWeight.w800, 
                                            color: const Color(0xFF0F172A),
                                            fontSize: 15,
                                          )
                                        ),
                                        Text(
                                          notif['time'], 
                                          style: TextStyle(color: Colors.grey.shade500, fontSize: 11)
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      notif['message'], 
                                      style: TextStyle(
                                        color: Colors.black87, 
                                        height: 1.4,
                                        fontWeight: isRead ? FontWeight.normal : FontWeight.w500
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: widget.isAdmin 
          ? FloatingActionButton.extended(
              onPressed: _showComposeMessageSheet,
              backgroundColor: const Color(0xFF0F172A),
              icon: const Icon(Icons.podcasts, color: Colors.white),
              label: const Text("Broadcast", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }
}