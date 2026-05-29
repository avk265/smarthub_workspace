import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class NotificationsScreen extends StatefulWidget {
  final String token;
  final VoidCallback onUnauthorized;

  const NotificationsScreen({super.key, required this.token, required this.onUnauthorized});

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

  Future<void> _fetchUserNotifications() async {
    // Note: Since a specific GET /notifications endpoint wasn't in the base PDF API list,
    // this simulates fetching personal alerts (Chat replies, Todo reminders, System alerts).
    // You can wire this up to a real endpoint once you build it, or keep the mock data for the demo!
    
    await Future.delayed(const Duration(milliseconds: 800)); // Simulate network delay
    
    if (mounted) {
      setState(() {
        notifications = [
          {
            "id": "1",
            "type": "chat",
            "title": "New AI Response",
            "message": "SmartHub has finished generating a summary for your document.",
            "is_read": false,
            "time": "Just now"
          },
          {
            "id": "2",
            "type": "todo",
            "title": "Task Reminder",
            "message": "Your task 'Submit Frontend Build' is due tomorrow.",
            "is_read": false,
            "time": "2 hours ago"
          },
          {
            "id": "3",
            "type": "system",
            "title": "Security Alert",
            "message": "A new login was detected on a Web Browser.",
            "is_read": true,
            "time": "Yesterday"
          }
        ];
        isLoading = false;
      });
    }
  }

  void _markAllAsRead() {
    setState(() {
      for (var notif in notifications) {
        notif['is_read'] = true;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All notifications marked as read.')),
    );
  }

  // --- UPGRADED: MULTI-CHANNEL SINGLE DISPATCH ---
  void _showComposeMessageSheet() {
    final TextEditingController recipientController = TextEditingController();
    final TextEditingController messageController = TextEditingController();
    bool isSending = false;
    String selectedChannel = 'email'; // Default channel

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            
            // Dynamic UI helpers
            bool isPhone = selectedChannel == 'sms' || selectedChannel == 'whatsapp';
            String hintText = isPhone ? "+1 (555) 123-4567" : "student@example.com";
            IconData prefixIcon = isPhone ? Icons.phone_android : Icons.alternate_email;
            
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 24, right: 24, top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Send Direct Message', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  const SizedBox(height: 16),
                  
                  // Channel Selector
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'email', label: Text('Email'), icon: Icon(Icons.email_outlined)),
                      ButtonSegment(value: 'sms', label: Text('SMS'), icon: Icon(Icons.message_outlined)),
                      ButtonSegment(value: 'whatsapp', label: Text('WhatsApp'), icon: Icon(Icons.chat_outlined)),
                    ],
                    selected: {selectedChannel},
                    onSelectionChanged: (Set<String> newSelection) {
                      setModalState(() {
                        selectedChannel = newSelection.first;
                        recipientController.clear(); // Clear input when switching types
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

                  TextField(
                    controller: recipientController,
                    keyboardType: isPhone ? TextInputType.phone : TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: isPhone ? 'Recipient Phone Number' : 'Recipient Email',
                      hintText: hintText,
                      prefixIcon: Icon(prefixIcon),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  TextField(
                    controller: messageController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Message content...',
                      border: OutlineInputBorder(),
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
                      if (recipientController.text.isEmpty || messageController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
                        return;
                      }
                      
                      setModalState(() => isSending = true);

                      try {
                        final response = await http.post(
                          Uri.parse('$apiUrl/notify/send'),
                          headers: {
                            'Content-Type': 'application/json',
                            'Authorization': 'Bearer ${widget.token}',
                          },
                          body: json.encode({
                            'channel': selectedChannel, // Sends the selected channel to FastAPI
                            'recipient': recipientController.text.trim(),
                            'message': messageController.text.trim(),
                          }),
                        );

                        if (response.statusCode == 200) {
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message sent via ${selectedChannel.toUpperCase()}!'), backgroundColor: Colors.green));
                          }
                        } else if (response.statusCode == 401) {
                          widget.onUnauthorized();
                        } else {
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send message.'), backgroundColor: Colors.red));
                        }
                      } catch (e) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Network error.'), backgroundColor: Colors.red));
                      } finally {
                        setModalState(() => isSending = false);
                      }
                    },
                    child: isSending 
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text('SEND VIA ${selectedChannel.toUpperCase()}', style: const TextStyle(fontWeight: FontWeight.bold)),
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
                    
                    return Card(
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
                    );
                  },
                ),
      // --- UPGRADED: FLOATING ACTION BUTTON ---
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showComposeMessageSheet,
        backgroundColor: const Color(0xFF0F172A),
        icon: const Icon(Icons.edit_square, color: Colors.white),
        label: const Text("New Message", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }
}