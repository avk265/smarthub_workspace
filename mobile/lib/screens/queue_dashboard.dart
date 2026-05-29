import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class QueueDashboard extends StatefulWidget {
  final String token;
  final VoidCallback onUnauthorized;
  
  const QueueDashboard({super.key, required this.token, required this.onUnauthorized});

  @override
  State<QueueDashboard> createState() => _QueueDashboardState();
}

class _QueueDashboardState extends State<QueueDashboard> {
  // Use 10.0.2.2 for Android emulator, or localhost for web/iOS simulator
  final String apiUrl = 'http://localhost:8000/api/v1'; 
  List<Map<String, dynamic>> jobs = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) => _pollJobStatus());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _showCreateJobSheet() {
    final TextEditingController totalController = TextEditingController(text: "10");
    final TextEditingController messageController = TextEditingController();
    String selectedChannel = 'email'; // Default to email, Push is removed!
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 24, right: 24, top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Create Worker Job', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  
                  // Notice: Push is gone! Only background worker tasks remain.
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'email', label: Text('Email'), icon: Icon(Icons.email)),
                      ButtonSegment(value: 'sms', label: Text('SMS'), icon: Icon(Icons.sms)),
                      ButtonSegment(value: 'whatsapp', label: Text('WhatsApp'), icon: Icon(Icons.chat)),
                    ],
                    selected: {selectedChannel},
                    onSelectionChanged: (Set<String> newSelection) {
                      setModalState(() => selectedChannel = newSelection.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  TextField(
                    controller: totalController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Total Messages to Simulate/Send',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  TextField(
                    controller: messageController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Message Content',
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
                    onPressed: isSubmitting ? null : () async {
                      if (messageController.text.isEmpty || totalController.text.isEmpty) return;
                      
                      setModalState(() => isSubmitting = true);
                      
                      try {
                        // Hits the bulk endpoint for RabbitMQ processing
                        final response = await http.post(
                          Uri.parse('$apiUrl/notify/bulk'),
                          headers: {
                            'Content-Type': 'application/json',
                            'Authorization': 'Bearer ${widget.token}',
                          },
                          body: json.encode({
                            'channel': selectedChannel,
                            'total': int.parse(totalController.text),
                            'message': messageController.text
                          }),
                        );

                        if (response.statusCode == 202) {
                          final data = json.decode(response.body);
                          if (mounted) {
                            Navigator.pop(context); // Close the sheet
                            
                            // Instantly add the new job to the UI queue list
                            setState(() {
                              jobs.insert(0, {
                                'id': data['job_id'],
                                'channel': selectedChannel,
                                'progress': 0.0,
                                'status': 'queued',
                                'failed': 0,
                              });
                            });
                            
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Job queued successfully!'), backgroundColor: Colors.green)
                            );
                          }
                        } else if (response.statusCode == 401 || response.statusCode == 403) {
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Admin privileges required.'), backgroundColor: Colors.red)
                            );
                          }
                        }
                      } catch (e) {
                         ScaffoldMessenger.of(context).showSnackBar(
                           const SnackBar(content: Text('Failed to queue job.'), backgroundColor: Colors.red)
                         );
                      } finally {
                        setModalState(() => isSubmitting = false);
                      }
                    },
                    child: isSubmitting 
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('QUEUE JOB', style: TextStyle(fontWeight: FontWeight.bold)),
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

  Future<void> _pollJobStatus() async {
    for (int i = 0; i < jobs.length; i++) {
      if (jobs[i]['progress'] >= 1.0) continue;

      try {
        final response = await http.get(
          Uri.parse('$apiUrl/notify/jobs/${jobs[i]['id']}'),
          headers: {'Authorization': 'Bearer ${widget.token}'}
        );
        
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          
          double totalProcessed = data['sent'] + data['failed'] + (data['retrying'] * 0.2);
          double progress = data['total'] > 0 ? totalProcessed / data['total'] : 0.0;
          
          if (progress > 0.95 && (data['sent'] + data['failed'] < data['total'])) {
            progress = 0.95; 
          }

          setState(() {
            jobs[i]['progress'] = progress;
            jobs[i]['failed'] = data['failed']; 
            jobs[i]['status'] = (data['sent'] + data['failed'] >= data['total']) ? 'completed' : 'processing';
          });
        }
      } catch (e) {
        debugPrint('Error polling job: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wrapped in a Scaffold so we can use a FloatingActionButton
    return Scaffold(
      backgroundColor: Colors.transparent, // Inherits the background color from MainLayout
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'ACTIVE QUEUE', 
              style: TextStyle(color: Colors.black45, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)
            ),
            const SizedBox(height: 16),
            Expanded(
              child: jobs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 16),
                          Text('System idle. Awaiting tasks.', style: TextStyle(color: Colors.grey.shade500)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: jobs.length,
                      itemBuilder: (context, index) {
                        final job = jobs[index];
                        return Card(
                          color: Colors.white,
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Colors.black12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${job['channel'].toString().toUpperCase()} DISPATCH', 
                                      style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF0F172A))
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: job['status'] == 'completed' 
                                            ? ((job['failed'] ?? 0) > 0 ? Colors.orange.shade50 : Colors.green.shade50) 
                                            : Colors.blue.shade50,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        job['status'] == 'completed' 
                                            ? ((job['failed'] ?? 0) > 0 ? 'COMPLETED (${job['failed']} FAILED)' : 'COMPLETED')
                                            : job['status'].toString().toUpperCase(),
                                        style: TextStyle(
                                          color: job['status'] == 'completed' 
                                              ? ((job['failed'] ?? 0) > 0 ? Colors.orange.shade800 : Colors.green.shade700) 
                                              : Colors.blue.shade700,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        )
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text('ID: ${job['id']}', style: const TextStyle(color: Colors.black38, fontSize: 11, fontFamily: 'monospace')),
                                const SizedBox(height: 16),
                                LinearProgressIndicator(
                                  value: job['progress'],
                                  backgroundColor: Colors.grey.shade100,
                                  color: const Color(0xFF0F172A), 
                                  minHeight: 6,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      // --- THE NEW BUTTON TO CREATE JOBS ---
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _showCreateJobSheet,
        backgroundColor: const Color(0xFF0F172A),
        icon: const Icon(Icons.add_task, color: Colors.white),
        label: const Text("New Job", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }
}