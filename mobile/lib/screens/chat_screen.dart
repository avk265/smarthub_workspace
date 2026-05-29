import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_markdown/flutter_markdown.dart';

class ChatScreen extends StatefulWidget {
  final String token;
  final VoidCallback onUnauthorized;

  const ChatScreen({super.key, required this.token, required this.onUnauthorized});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final String apiUrl = 'http://localhost:8000/api/v1';
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  String? sessionId; 
  List<Map<String, dynamic>> messages = [];
  List<String> processingLogs = [];
  String currentAiMessage = "";
  bool isAiThinking = false;

  // Sidebar History Variables
  List<dynamic> chatSessions = [];
  bool isLoadingHistory = false;

  @override
  void initState() {
    super.initState();
    _fetchSessions(); // Fetch old chats for the sidebar
    // Create a new chat for the main screen
  }

  // --- API Methods ---
// --- NEW DELETE METHOD ---
  Future<void> _deleteSession(String id) async {
    try {
      final response = await http.delete(
        Uri.parse('$apiUrl/chat/sessions/$id'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode == 200) {
        setState(() {
          // 1. Remove it from the sidebar list
          chatSessions.removeWhere((session) => session['id'] == id);
          
          // 2. If we just deleted the chat we are currently looking at, clear the screen!
          if (sessionId == id) {
            sessionId = null;
            messages.clear();
            
          }
        });
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      }
    } catch (e) {
      debugPrint("Error deleting session: $e");
    }
  }
  Future<void> _fetchSessions() async {
    try {
      final response = await http.get(
        Uri.parse('$apiUrl/chat/sessions'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode == 200) {
        setState(() {
          chatSessions = json.decode(response.body);
        });
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      }
    } catch (e) {
      debugPrint("Error fetching sessions: $e");
    }
  }

  Future<void> _loadSessionHistory(String id) async {
    // 1. Close the sidebar drawer
    Navigator.pop(context); 
    
    // 2. Clear the screen and show loading
    setState(() {
      isLoadingHistory = true;
      sessionId = id;
      messages.clear();
      currentAiMessage = "";
      processingLogs.clear();
      isAiThinking = false;
    });

    try {
      // 3. Fetch the past messages for this specific chat
      final response = await http.get(
        Uri.parse('$apiUrl/chat/sessions/$id/messages'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> history = json.decode(response.body);
        setState(() {
          messages = history.map((msg) => {
            "role": msg["role"],
            "content": msg["content"]
          }).toList();
        });
        
        Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      }
    } catch (e) {
      debugPrint("Error loading history: $e");
    } finally {
      setState(() {
        isLoadingHistory = false;
      });
    }
  }

  Future<void> _createNewSession() async {
    try {
      final response = await http.post(
        Uri.parse('$apiUrl/chat/sessions'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: json.encode({"title": "New Chat"}),
      );

      if (response.statusCode == 201) {
        final data = json.decode(response.body);
        setState(() {
          sessionId = data['id']; 
        });
        // Refresh the sidebar to show this new chat
        _fetchSessions();
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      }
    } catch (e) {
      debugPrint("Error creating session: $e");
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || sessionId == null) return;

    setState(() {
      messages.add({"role": "user", "content": text});
      _controller.clear();
      processingLogs.clear();
      currentAiMessage = "";
      isAiThinking = true;
    });
    
    _scrollToBottom();

    final request = http.Request('POST', Uri.parse('$apiUrl/chat/sessions/$sessionId/messages'));
    request.headers.addAll({
      'Authorization': 'Bearer ${widget.token}',
      'Content-Type': 'application/json'
    });
    request.body = json.encode({'content': text});

    try {
      final client = http.Client();
      final response = await client.send(request);

      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.startsWith('data: ')) {
            final jsonString = line.substring(6).trim();
            if (jsonString.isNotEmpty) {
              try {
                final parsed = json.decode(jsonString);

                setState(() {
                  if (parsed['type'] == 'log') {
                    processingLogs.add(parsed['message']);
                  } else if (parsed['type'] == 'content') {
                    currentAiMessage += parsed['content'];
                  } else if (parsed['type'] == 'done') {
                    isAiThinking = false;
                    messages.add({"role": "assistant", "content": currentAiMessage});
                    currentAiMessage = "";
                    processingLogs.clear();
                    
                    // Fetch sessions again just in case the title updated
                    _fetchSessions();
                  }
                  _scrollToBottom();
                });
              } catch (e) {
                // Ignore broken JSON fragments
              }
            }
          }
        },
        onError: (error) {
          debugPrint("Stream closed by browser: $error");
          setState(() {
            isAiThinking = false;
            if (currentAiMessage.isNotEmpty) {
              messages.add({"role": "assistant", "content": currentAiMessage});
              currentAiMessage = "";
            }
          });
        },
        cancelOnError: true, 
      );
    } catch (e) {
      setState(() {
        isAiThinking = false;
        messages.add({"role": "assistant", "content": "Error connecting to AI server."});
      });
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // --- UI Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      
      // 1. App Bar
      appBar: AppBar(
        title: const Text("SmartHub AI", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        elevation: 1,
        // The Modern Sidebar Icon
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.view_sidebar_outlined), 
            tooltip: 'Chat History',
            onPressed: () {
              Scaffold.of(context).openDrawer(); 
            },
          ),
        ),
      ),
      
      // 2. Sidebar Drawer
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: Column(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Color(0xFF0F172A)),
              child: Center(
                child: Text('Chat History', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: Colors.blue),
              title: const Text('Start New Chat', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
              onTap: () {
                Navigator.pop(context); 
                setState(() { messages.clear(); sessionId = null; });
                _createNewSession(); 
              },
            ),
            const Divider(),
            Expanded(
              child: chatSessions.isEmpty
                  ? const Center(child: Text("No past chats.", style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: chatSessions.length,
                      itemBuilder: (context, index) {
                        final session = chatSessions[index];
                        final dateString = session['created_at'].toString().substring(0, 10);
                        final isActive = session['id'] == sessionId;

                        return Container(
                          color: isActive ? Colors.blue.withOpacity(0.1) : Colors.transparent,
                          child: ListTile(
                            leading: Icon(Icons.chat_bubble_outline, color: isActive ? Colors.blue : Colors.grey),
                            title: Text(session['title'] ?? 'New Chat', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                            subtitle: Text(dateString, style: const TextStyle(fontSize: 12)),
                            onTap: () => _loadSessionHistory(session['id']),
                            
                            // --- THE NEW DELETE ICON ---
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              tooltip: "Delete Chat",
                              onPressed: () {
                                // Optional: You could wrap this in a showDialog to ask "Are you sure?" first!
                                _deleteSession(session['id']);
                              },
                            ),
                            // ---------------------------
                            
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      
      // 3. Main Chat Body
      
      // 3. Main Chat Body
      body: sessionId == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text(
                    "Select a chat from the menu, or start a new one.",
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () {
                      _createNewSession();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F172A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text("Start New Chat", style: TextStyle(fontWeight: FontWeight.bold)),
                  )
                ],
              ),
            )
          : (isLoadingHistory 
              ? const Center(child: CircularProgressIndicator()) 
              : Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        // ... (keep all your existing ListView.builder code here exactly as it was) ...
                        itemCount: messages.length + (isAiThinking ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == messages.length && isAiThinking) {
                            return _buildActiveStreamBubble();
                          }
                          final msg = messages[index];
                          final isUser = msg['role'] == 'user';
                          
                          return Align(
                            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(12),
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                              decoration: BoxDecoration(
                                color: isUser ? Colors.blue[600] : Colors.grey[200],
                                borderRadius: BorderRadius.circular(16).copyWith(
                                  bottomRight: isUser ? const Radius.circular(0) : const Radius.circular(16),
                                  bottomLeft: !isUser ? const Radius.circular(0) : const Radius.circular(16),
                                ),
                              ),
                              child: MarkdownBody(
                                data: msg['content'] ?? '',
                                styleSheet: MarkdownStyleSheet(
                                  p: TextStyle(color: isUser ? Colors.white : Colors.black87, fontSize: 16),
                                  strong: TextStyle(color: isUser ? Colors.white : Colors.black, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    
                    // Input Area
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(top: BorderSide(color: Colors.grey.shade200)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              enabled: !isAiThinking,
                              decoration: InputDecoration(
                                hintText: "Ask SmartHub...",
                                hintStyle: TextStyle(color: Colors.grey.shade400),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade100,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                              ),
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          CircleAvatar(
                            backgroundColor: isAiThinking ? Colors.grey : const Color(0xFF0F172A),
                            child: IconButton(
                              icon: const Icon(Icons.arrow_upward, color: Colors.white),
                              onPressed: isAiThinking ? null : _sendMessage,
                            ),
                          )
                        ],
                      ),
                    )
                  ],
                )),
      );
  }

  // The sleek UI block showing the AI's internal process and live text
  Widget _buildActiveStreamBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(12).copyWith(bottomLeft: const Radius.circular(0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Processing Logs
            if (processingLogs.isNotEmpty && currentAiMessage.isEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: processingLogs.map((log) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text(log, style: TextStyle(fontSize: 12, color: Colors.blue.shade800, fontStyle: FontStyle.italic)),
                    ],
                  ),
                )).toList(),
              ),
              
            // Live Streamed Content
            if (currentAiMessage.isNotEmpty)
              MarkdownBody(
                data: currentAiMessage,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(color: Colors.black87, fontSize: 16, height: 1.4),
                  strong: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      ),
    );
  }
}