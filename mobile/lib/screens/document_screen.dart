import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
class DocumentScreen extends StatefulWidget {
  final String token;
  final VoidCallback onUnauthorized;

  const DocumentScreen({super.key, required this.token, required this.onUnauthorized});

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  final String apiUrl = 'http://localhost:8000/api/v1';
  List<dynamic> documents = [];
  bool isLoading = true;
  bool isUploading = false;

  @override
  void initState() {
    super.initState();
    _fetchDocuments();
  }

  Future<void> _fetchDocuments() async {
    setState(() => isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$apiUrl/documents'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode == 200) {
        setState(() => documents = json.decode(response.body));
      } else if (response.statusCode == 401) {
        widget.onUnauthorized();
      }
    } catch (e) {
      debugPrint("Error fetching documents: $e");
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _uploadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'txt', 'png', 'jpg'], 
    );

    if (result != null) {
      setState(() => isUploading = true);
      try {
        var request = http.MultipartRequest('POST', Uri.parse('$apiUrl/documents/upload'));
        request.headers['Authorization'] = 'Bearer ${widget.token}';

        // THE FIX: Handle Web vs Mobile file extraction
        if (kIsWeb) {
          request.files.add(http.MultipartFile.fromBytes(
            'file',
            result.files.single.bytes!,
            filename: result.files.single.name,
          ));
        } else {
          request.files.add(await http.MultipartFile.fromPath(
            'file',
            result.files.single.path!,
          ));
        }

        var response = await request.send();
        if (response.statusCode == 201) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Document uploaded!')));
          }
          _fetchDocuments(); 
        } else {
           debugPrint("Upload failed with status: ${response.statusCode}");
        }
      } catch (e) {
        debugPrint("Upload failed: $e");
      } finally {
        setState(() => isUploading = false);
      }
    }
  }
  Future<void> _deleteDocument(String id) async {
    try {
      final response = await http.delete(
        Uri.parse('$apiUrl/documents/$id'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode == 200) {
        _fetchDocuments(); // Refresh the list
      }
    } catch (e) {
      debugPrint("Delete failed: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('My Documents', style: TextStyle(fontSize: 18)),
        elevation: 0,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0F172A)))
          : documents.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_open, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text("No documents uploaded yet.", style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: documents.length,
                  itemBuilder: (context, index) {
                    final doc = documents[index];
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue.shade50,
                          child: Icon(
                            doc['file_type'] == 'pdf' ? Icons.picture_as_pdf : Icons.description,
                            color: Colors.blue.shade700,
                          ),
                        ),
                        title: Text(doc['filename'], style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(doc['processed'] ? "Indexed for AI" : "Processing..."),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                          onPressed: () => _deleteDocument(doc['id']),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: "doc_upload_btn", // <-- ADD THIS LINE
        onPressed: isUploading ? null : _uploadFile,
        backgroundColor: const Color(0xFF0F172A),
        icon: isUploading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.upload_file, color: Colors.white),
        label: Text(isUploading ? "Uploading..." : "Upload File", style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}