import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class TodoScreen extends StatefulWidget {
  final String token;
  final VoidCallback onUnauthorized;

  const TodoScreen({super.key, required this.token, required this.onUnauthorized});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  final String apiUrl = 'http://localhost:8000/api/v1'; // Use 10.0.2.2 for Android Emulator
  List<dynamic> todos = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchTodos();
  }

  Future<void> _fetchTodos() async {
    setState(() => isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$apiUrl/todos'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode == 200) {
        setState(() {
          todos = json.decode(response.body);
          todos.sort((a, b) {
            if (a['completed'] == b['completed']) return 0;
            return a['completed'] ? 1 : -1;
          });
          isLoading = false;
        });
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      }
    } catch (e) {
      debugPrint("Error fetching todos: $e");
      setState(() => isLoading = false);
    }
  }

  // UPGRADED: Now accepts due_date
  Future<void> _addTodo(String title, String description, DateTime? dueDate) async {
    if (title.trim().isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('$apiUrl/todos'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: json.encode({
          'title': title.trim(),
          'description': description.trim(),
          'due_date': dueDate?.toIso8601String(), // Send formatted date to FastAPI
        }),
      );

      if (response.statusCode == 201) {
        _fetchTodos();
      }
    } catch (e) {
      debugPrint("Error adding todo: $e");
    }
  }

  Future<void> _toggleTodo(String id) async {
    final index = todos.indexWhere((t) => t['id'] == id);
    if (index != -1) {
      setState(() {
        todos[index]['completed'] = !todos[index]['completed'];
      });
    }

    try {
      final response = await http.put(
        Uri.parse('$apiUrl/todos/$id/complete'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) _fetchTodos(); 
    } catch (e) {
      _fetchTodos();
    }
  }

  Future<void> _deleteTodo(String id) async {
    setState(() {
      todos.removeWhere((t) => t['id'] == id);
    });

    try {
      await http.delete(
        Uri.parse('$apiUrl/todos/$id'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
    } catch (e) {
      _fetchTodos();
    }
  }

  // Helper to format the date nicely for the UI
  String _formatDate(String isoDate) {
    final date = DateTime.parse(isoDate).toLocal();
    return "${date.month}/${date.day}/${date.year}";
  }

  // THE TRIGGER LOGIC: Checks if the task is due within 48 hours
  bool _isUrgent(String? isoDate, bool isCompleted) {
    if (isoDate == null || isCompleted) return false;
    final dueDate = DateTime.parse(isoDate).toLocal();
    final now = DateTime.now();
    final difference = dueDate.difference(now).inDays;
    
    // Trigger is true if it is due in 2 days or less (including overdue)
    return difference <= 2; 
  }

  // UPGRADED: Added DatePicker to the dialog
  void _showAddDialog() {
    final TextEditingController titleController = TextEditingController();
    final TextEditingController descController = TextEditingController();
    DateTime? selectedDate;

    showDialog(
      context: context,
      builder: (context) {
        // StatefulBuilder is required here so the dialog updates when a date is picked
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('New Task', style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: titleController,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Task Title', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descController,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Description (Optional)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  
                  // --- DATE PICKER BUTTON ---
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12,horizontal: 16),
                      alignment: Alignment.centerLeft,
                    ),
                    
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      selectedDate == null 
                          ? "Set Due Date" 
                          : "Due: ${_formatDate(selectedDate!.toIso8601String())}",
                      style: TextStyle(color: selectedDate == null ? Colors.black54 : const Color(0xFF0F172A)),
                    ),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now().add(const Duration(days: 1)),
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2030),
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.light(
                                primary: Color(0xFF0F172A), 
                                onPrimary: Colors.white, 
                                onSurface: Colors.black, 
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDate = picked);
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0F172A)),
                  onPressed: () {
                    _addTodo(titleController.text, descController.text, selectedDate);
                    Navigator.pop(context);
                  },
                  child: const Text('ADD TASK', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0F172A)))
          : todos.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text("You're all caught up!", style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: todos.length,
                  itemBuilder: (context, index) {
                    final todo = todos[index];
                    final bool isCompleted = todo['completed'];
                    final bool hasDescription = todo['description'] != null && todo['description'].toString().trim().isNotEmpty;
                    final bool hasDueDate = todo['due_date'] != null;
                    
                    // Trigger the urgent warning
                    final bool isUrgent = _isUrgent(todo['due_date'], isCompleted);

                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          // Visual Trigger: Red border if urgent, otherwise standard grey
                          color: isUrgent ? Colors.redAccent.withOpacity(0.5) : (isCompleted ? Colors.transparent : Colors.black12),
                          width: isUrgent ? 1.5 : 1.0,
                        ),
                      ),
                      color: isUrgent ? Colors.red.shade50 : (isCompleted ? Colors.grey.shade100 : Colors.white),
                      child: ListTile(
                        leading: Checkbox(
                          value: isCompleted,
                          activeColor: const Color(0xFF0F172A),
                          onChanged: (_) => _toggleTodo(todo['id']),
                        ),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                todo['title'],
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: isCompleted ? Colors.grey : const Color(0xFF0F172A),
                                  decoration: isCompleted ? TextDecoration.lineThrough : null,
                                ),
                              ),
                            ),
                            // Display the Due Date visually 
                            if (hasDueDate)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isUrgent ? Colors.redAccent : Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _formatDate(todo['due_date']),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isUrgent ? Colors.white : Colors.black54,
                                    decoration: isCompleted ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: hasDescription
                            ? Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Text(
                                  todo['description'],
                                  style: TextStyle(
                                    color: isCompleted ? Colors.grey.shade400 : Colors.black54,
                                    decoration: isCompleted ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                              )
                            : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                          onPressed: () => _deleteTodo(todo['id']),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        backgroundColor: const Color(0xFF0F172A),
        onPressed: _showAddDialog,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}