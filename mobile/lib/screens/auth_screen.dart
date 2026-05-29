import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // Needed to check if running on Chrome
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_web/web_only.dart' as web; // The official Google Web Button
import 'dart:convert';
import 'dart:io';

import 'main_layout.dart';
import 'reset_password_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  // 1. Use the new Version 7 Singleton Instance
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  bool isLogin = true;
  bool isLoading = false;
  
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  
  final String apiUrl = 'http://localhost:8000/api/v1'; 
  final String simulatedDeviceToken = "fcm_token_";

  File? _profileImage;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _setupGoogleSignIn();
  }

  // --- VERSION 7 UNIFIED GOOGLE SIGN-IN LOGIC ---
  // --- VERSION 7 UNIFIED GOOGLE SIGN-IN LOGIC ---
  void _setupGoogleSignIn() {
    // 1. Initialize exactly once (Required in V7)
    _googleSignIn.initialize(
      clientId: 'PASTE_YOUR_WEB_CLIENT_ID_HERE.apps.googleusercontent.com', 
    ).then((_) {
      
      // 2. Listen for the new V7 authenticationEvents stream
      _googleSignIn.authenticationEvents.listen((event) async {
        
        // 3. Extract the user securely using Dart pattern matching
        final GoogleSignInAccount? account = switch (event) {
          GoogleSignInAuthenticationEventSignIn() => event.user,
          GoogleSignInAuthenticationEventSignOut() => null,
        };

        if (account != null) {
          setState(() => isLoading = true);
          try {
            // Retrieve the token synchronously (New in V7)
            final GoogleSignInAuthentication googleAuth = await account.authentication;
            
            if (googleAuth.idToken != null) {
              await _authenticateWithBackend(googleAuth.idToken!, 'google');
            } else {
              _showNotification('Failed to retrieve secure token from Google.', isError: true);
            }
          } catch (e) {
            debugPrint("Google Auth Error: $e");
            _showNotification('Authentication failed.', isError: true);
          } finally {
            if (mounted) setState(() => isLoading = false);
          }
        }
      });
      
    });
  }

  Future<void> _authenticateWithBackend(String idToken, String provider) async {
    try {
      final response = await http.post(
        Uri.parse('$apiUrl/auth/social'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'id_token': idToken,
          'provider': provider,
          'device_token': simulatedDeviceToken
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final String token = data['access_token'];
        
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('jwt_token', token);
        
        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => MainLayout(token: token)));
        }
      } else {
        _showNotification('Authentication rejected by server.', isError: true);
      }
    } catch (e) {
      _showNotification('Network error connecting to backend.', isError: true);
    }
  }
  // ----------------------------------------------

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() => _profileImage = File(image.path));
    }
  }

  void _showNotification(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isError ? Colors.redAccent.shade700 : Colors.green.shade800,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _showForgotPasswordDialog() async {
    final TextEditingController resetEmailController = TextEditingController();
    if (emailController.text.isNotEmpty) resetEmailController.text = emailController.text;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reset Password', style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your registered email address to receive a password reset link.', style: TextStyle(fontSize: 13, color: Colors.black54)),
              const SizedBox(height: 16),
              TextField(
                controller: resetEmailController,
                decoration: InputDecoration(
                  labelText: 'Email Address', 
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))
                ),
                keyboardType: TextInputType.emailAddress,
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
                onPressed: () async {
                  final email = resetEmailController.text.trim();
                  if (email.isEmpty) return;
                  Navigator.pop(context); 
                  try {
                    final response = await http.post(
                      Uri.parse('$apiUrl/auth/forgot-password'),
                      headers: {'Content-Type': 'application/json'},
                      body: json.encode({'email': email}),
                    );
                    if (response.statusCode == 200) {
                      final data = json.decode(response.body);
                      final String serverToken = data['reset_token'] ?? '';
                      if (serverToken.isNotEmpty && mounted) {
                        Navigator.push(context, MaterialPageRoute(builder: (context) => ResetPasswordScreen(token: serverToken)));
                      }
                    } else {
                      _showNotification('Failed to send OTP request.', isError: true);
                    }
                  } catch (e) {
                    _showNotification('Network error.', isError: true);
                  }
                },
                child: const Text('SEND OTP', style: TextStyle(color: Colors.white)),
              ),
          ],
        );
      },
    );
  }

  Future<void> submitAuth() async {
    if (emailController.text.trim().isEmpty || passwordController.text.trim().isEmpty) {
      _showNotification('Please fill in all mandatory fields (*)', isError: true);
      return;
    }

    setState(() => isLoading = true);
    
    try {
      if (isLogin) {
        final response = await http.post(
          Uri.parse('$apiUrl/auth/login'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'username': emailController.text.trim(),
            'password': passwordController.text.trim(),
            'device_token': simulatedDeviceToken,
          },
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final String token = data['access_token'];
          
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('jwt_token', token);
          
          if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => MainLayout(token: token)));
        } else {
          _showNotification('Invalid email or password.', isError: true);
        }
      } else {
        if (nameController.text.trim().isEmpty) {
          _showNotification('Full Name is mandatory (*)', isError: true);
          setState(() => isLoading = false);
          return;
        }

        var request = http.MultipartRequest('POST', Uri.parse('$apiUrl/auth/register'));
        request.fields['email'] = emailController.text.trim();
        request.fields['full_name'] = nameController.text.trim();
        request.fields['password'] = passwordController.text.trim();
        request.fields['device_token'] = simulatedDeviceToken;
        
        if (phoneController.text.trim().isNotEmpty) request.fields['phone'] = phoneController.text.trim();
        if (_profileImage != null) request.files.add(await http.MultipartFile.fromPath('avatar', _profileImage!.path));

        var streamedResponse = await request.send().timeout(const Duration(seconds: 20));
        var response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode == 201) {
          setState(() {
            isLogin = true;
            passwordController.clear();
            _profileImage = null; 
          });
          _showNotification('Registration successful! You can now log in.');
        } else if (response.statusCode == 400) {
          _showNotification('An account with this email already exists.', isError: true);
        } else {
          _showNotification('Failed to create account.', isError: true);
        }
      }
    } catch (e) {
      _showNotification('Network error. Ensure the server is running.', isError: true);
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Widget _buildTextField({required TextEditingController controller, required String label, bool isPassword = false, TextInputType type = TextInputType.text}) {
    return TextField(
      controller: controller,
      obscureText: isPassword,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        filled: true,
        fillColor: Colors.grey.shade50,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.blueAccent, width: 2)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200, width: 1)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9), 
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420), 
            child: Card(
              elevation: 4,
              shadowColor: Colors.black12,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 40.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.hub_rounded, size: 56, color: const Color(0xFF0F172A).withOpacity(0.9)),
                    const SizedBox(height: 16),
                    Text(
                      isLogin ? 'Welcome Back' : 'Create Account',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF0F172A), letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isLogin ? 'Enter your details to access your workspace.' : 'Sign up to get started with SmartHub.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                    ),
                    const SizedBox(height: 32),
                    
                    if (!isLogin) ...[
                      Align(
                        alignment: Alignment.center,
                        child: GestureDetector(
                          onTap: _pickImage,
                          child: CircleAvatar(
                            radius: 40,
                            backgroundColor: Colors.blueAccent.withOpacity(0.08),
                            backgroundImage: _profileImage != null ? FileImage(_profileImage!) : null,
                            child: _profileImage == null
                                ? const Icon(Icons.add_a_photo_outlined, size: 28, color: Colors.blueAccent)
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildTextField(controller: nameController, label: 'Full Name *'),
                      const SizedBox(height: 16),
                      _buildTextField(controller: phoneController, label: 'Phone Number (Optional)', type: TextInputType.phone),
                      const SizedBox(height: 16),
                    ],
                    
                    _buildTextField(controller: emailController, label: isLogin ? 'Email Address' : 'Email Address *', type: TextInputType.emailAddress),
                    const SizedBox(height: 16),
                    _buildTextField(controller: passwordController, label: isLogin ? 'Password' : 'Password *', isPassword: true),
                    
                    if (isLogin)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _showForgotPasswordDialog,
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          child: const Text('Forgot Password?', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                      ),
                      
                    const SizedBox(height: 24),

                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16), 
                        backgroundColor: const Color(0xFF0F172A),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                      ),
                      onPressed: isLoading ? null : submitAuth,
                      child: isLoading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text(isLogin ? 'Sign In' : 'Create Account', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                    ),
                    
                    const SizedBox(height: 24),

                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text("OR", style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w600, fontSize: 12)),
                        ),
                        Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // --- THE DYNAMIC SOCIAL BUTTON ---
                    kIsWeb 
                    ? SizedBox(
                        height: 48,
                        width: double.infinity,
                        // If Web: Show the un-clickable, Google-rendered security button
                        child: web.renderButton(), 
                      )
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          backgroundColor: Colors.white,
                        ),
                        // If Mobile: Allow them to click our custom button!
                        onPressed: isLoading ? null : () async {
                          setState(() => isLoading = true);
                          try {
                            await _googleSignIn.authenticate();
                            // The listener in initState() will catch the result!
                          } catch (e) {
                            _showNotification('Sign-In canceled.', isError: true);
                            setState(() => isLoading = false);
                          }
                        },
                        icon: Image.network('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/120px-Google_%22G%22_logo.svg.png', height: 20),
                        label: Text('Continue with Google', style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w600)),
                      ),

                    const SizedBox(height: 24),
                    
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(isLogin ? "Don't have an account? " : "Already have an account? ", style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              isLogin = !isLogin;
                              passwordController.clear();
                            });
                          },
                          child: Text(
                            isLogin ? 'Sign up' : 'Log in', 
                            style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 14)
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}