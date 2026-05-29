import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb; 
import 'dart:io' as io; 

class UserManagementScreen extends StatefulWidget {
  final String token;
  final VoidCallback onUnauthorized; // Secure logout callback

  const UserManagementScreen({
    super.key, 
    required this.token,
    required this.onUnauthorized,
  });

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final String apiUrl = 'http://localhost:8000/api/v1';
  List<dynamic> users = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<void> _fetchUsers() async {
    setState(() => isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$apiUrl/admin/users'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode == 200) {
        setState(() {
          users = json.decode(response.body);
          isLoading = false;
        });
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      } else {
        setState(() => isLoading = false);
      }
    } catch (e) {
      debugPrint("Error fetching users: $e");
      setState(() => isLoading = false);
    }
  }

  Future<void> _deleteUser(String id) async {
    final backupUsers = List.from(users);
    setState(() => users.removeWhere((u) => u['id'] == id));

    try {
      final response = await http.delete(
        Uri.parse('$apiUrl/admin/users/$id'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      
      if (response.statusCode == 401) {
        widget.onUnauthorized();
        return;
      } else if (response.statusCode != 200) {
        setState(() => users = backupUsers); 
        _showSnackBar("Failed to delete user.", true);
      } else {
        _showSnackBar("User deleted successfully.", false);
      }
    } catch (e) {
      setState(() => users = backupUsers);
      _showSnackBar("Network error.", true);
    }
  }

  Future<void> _pickAndUploadCSV() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: kIsWeb, 
      );

      if (result == null || result.files.isEmpty) return;

      PlatformFile file = result.files.first;
      String fileContent = '';

      // --- PLATFORM-SPECIFIC FILE READING ---
      if (kIsWeb) {
        if (file.bytes == null) {
          _showSnackBar("Failed to read file on Web.", true);
          return;
        }
        fileContent = utf8.decode(file.bytes!);
      } else {
        if (file.path == null) {
          _showSnackBar("Failed to read file path on Mobile.", true);
          return;
        }
        fileContent = await io.File(file.path!).readAsString();
      }

      // --- STRICT CLIENT-SIDE CSV VALIDATION ---
      List<String> lines = fileContent.split('\n');
      if (lines.isEmpty) {
        _showSnackBar("CSV file is empty.", true);
        return;
      }

      String headerRow = lines.first.trim().toLowerCase();
      if (headerRow != 'email,full_name,phone') {
        _showSnackBar("Invalid Format. Header must be exactly: email,full_name,phone", true);
        return;
      }
      // ------------------------------------------

      _uploadToBackend(file);

    } catch (e) {
      _showSnackBar("Error selecting file: $e", true);
    }
  }

  Future<void> _uploadToBackend(PlatformFile file) async {
    setState(() => isLoading = true);
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$apiUrl/admin/users/bulk'),
      );
      
      request.headers['Authorization'] = 'Bearer ${widget.token}';
      
      if (kIsWeb) {
        request.files.add(http.MultipartFile.fromBytes(
          'file', 
          file.bytes!, 
          filename: file.name
        ));
      } else {
        request.files.add(await http.MultipartFile.fromPath(
          'file', 
          file.path!
        ));
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 401) {
        widget.onUnauthorized();
        return;
      } else if (response.statusCode == 202) {
        _showSnackBar("CSV uploaded! Processing users in background...", false);
        await Future.delayed(const Duration(seconds: 2));
        _fetchUsers();
      } else {
        _showSnackBar("Upload failed: ${response.body}", true);
        setState(() => isLoading = false);
      }
    } catch (e) {
      _showSnackBar("Upload error: $e", true);
      setState(() => isLoading = false);
    }
  }

  void _showSnackBar(String message, bool isError) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('User Management', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: Colors.grey.shade200, height: 1.0),
        ),
      ),
      body: Column(
        children: [
          // Action Bar
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Bulk Import", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text("Format: email,full_name,phone", style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.upload_file, color: Colors.white, size: 18),
                  label: const Text('UPLOAD CSV', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: isLoading ? null : _pickAndUploadCSV,
                ),
              ],
            ),
          ),
          
          // User List
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF0F172A)))
                : users.isEmpty
                    ? Center(child: Text("No users found.", style: TextStyle(color: Colors.grey.shade600)))
                    : ListView.builder(
                        itemCount: users.length,
                        itemBuilder: (context, index) {
                          final user = users[index];
                          final bool isAdmin = user['is_admin'] ?? false;
                          
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.grey.shade200),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isAdmin ? const Color(0xFF0F172A) : Colors.grey.shade200,
                                child: Icon(
                                  isAdmin ? Icons.admin_panel_settings : Icons.person, 
                                  color: isAdmin ? Colors.white : Colors.grey.shade600
                                ),
                              ),
                              title: Text(
                                user['full_name'] ?? 'Unknown',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(user['email'] ?? 'No email'),
                              trailing: isAdmin 
                                ? const SizedBox.shrink() 
                                : IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                    onPressed: () => _deleteUser(user['id']),
                                    tooltip: "Delete User",
                                  ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}