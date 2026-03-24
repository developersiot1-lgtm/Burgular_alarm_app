import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'favourite_screen.dart';

// ================================================================
// login_screen.dart
// Shows: Login  ↔  Register  ↔  Forgot Password (OTP) ↔ Reset Password
// On success → FavoritesScreen (which now loads only the user's devices)
// ================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  // ── Tab / page state ─────────────────────────────────────────
  _AuthPage _page = _AuthPage.login;

  // ── Controllers ──────────────────────────────────────────────
  final _nameCtrl     = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _passCtrl     = TextEditingController();
  final _confirmCtrl  = TextEditingController();
  final _otpCtrl      = TextEditingController();
  final _newPassCtrl  = TextEditingController();

  // ── State ────────────────────────────────────────────────────
  bool   _loading     = false;
  bool   _obscurePass = true;
  String _otpEmail    = ''; // email used in forgot flow

  late AnimationController _anim;
  late Animation<double>   _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeIn);
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    for (final c in [_nameCtrl, _emailCtrl, _passCtrl, _confirmCtrl,
      _otpCtrl, _newPassCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _switchPage(_AuthPage page) {
    _anim.reset();
    setState(() => _page = page);
    _anim.forward();
  }

  // ── NAV to home after login/register ─────────────────────────
  void _goHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const FavoritesScreen()),
    );
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  // ── ACTIONS ──────────────────────────────────────────────────

  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text.trim();
    if (email.isEmpty || pass.isEmpty) {
      _showSnack('Enter email and password', error: true);
      return;
    }
    setState(() => _loading = true);
    final result = await AuthService().login(email: email, password: pass);
    setState(() => _loading = false);
    if (result.success) {
      _goHome();
    } else {
      _showSnack(result.message, error: true);
    }
  }

  Future<void> _register() async {
    final name    = _nameCtrl.text.trim();
    final email   = _emailCtrl.text.trim();
    final pass    = _passCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();

    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      _showSnack('All fields are required', error: true); return;
    }
    if (pass != confirm) {
      _showSnack('Passwords do not match', error: true); return;
    }
    if (pass.length < 6) {
      _showSnack('Password must be at least 6 characters', error: true); return;
    }

    setState(() => _loading = true);
    final result = await AuthService().register(name: name, email: email, password: pass);
    setState(() => _loading = false);
    if (result.success) {
      _goHome();
    } else {
      _showSnack(result.message, error: true);
    }
  }

  Future<void> _sendOtp() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      _showSnack('Enter your email', error: true); return;
    }
    setState(() => _loading = true);
    final result = await AuthService().forgotPassword(email);
    setState(() => _loading = false);
    if (result.success) {
      _otpEmail = email;
      _otpCtrl.clear(); // always start with empty OTP field
      _showSnack(result.message);
      _switchPage(_AuthPage.otpVerify);
    } else {
      _showSnack(result.message, error: true);
    }
  }

  Future<void> _verifyOtp() async {
    // Strip ALL spaces — Gmail sometimes adds spaces when copying
    final otp = _otpCtrl.text.trim().replaceAll(' ', '');
    if (otp.length != 6) {
      _showSnack('Enter the 6-digit code (numbers only)', error: true); return;
    }
    setState(() => _loading = true);
    final result = await AuthService().verifyOtp(_otpEmail, otp);
    setState(() => _loading = false);
    if (result.success) {
      _switchPage(_AuthPage.resetPassword);
    } else {
      _showSnack(result.message, error: true);
    }
  }

  Future<void> _resetPassword() async {
    final newPass = _newPassCtrl.text.trim();
    final otp     = _otpCtrl.text.trim().replaceAll(' ', '');
    if (newPass.length < 6) {
      _showSnack('Password must be at least 6 characters', error: true); return;
    }
    setState(() => _loading = true);
    final result = await AuthService().resetPassword(
      email: _otpEmail, otp: otp, newPassword: newPass,
    );
    setState(() => _loading = false);
    if (result.success) {
      _showSnack('Password updated! Please log in.');
      _switchPage(_AuthPage.login);
    } else {
      _showSnack(result.message, error: true);
    }
  }

  // ── BUILD ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D1B2A), Color(0xFF1B2838), Color(0xFF0A0F1E)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: FadeTransition(
                opacity: _fade,
                child: _buildCurrentPage(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentPage() {
    switch (_page) {
      case _AuthPage.login:         return _buildLogin();
      case _AuthPage.register:      return _buildRegister();
      case _AuthPage.forgotEmail:   return _buildForgotEmail();
      case _AuthPage.otpVerify:     return _buildOtpVerify();
      case _AuthPage.resetPassword: return _buildResetPassword();
    }
  }

  // ── Shared Widgets ────────────────────────────────────────────

  Widget _logo() => Column(children: [
    Container(
      width: 80, height: 80,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Colors.blue, Color(0xFF0D47A1)]),
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.blue.withOpacity(0.4), blurRadius: 20)],
      ),
      child: const Icon(Icons.security, size: 44, color: Colors.white),
    ),
    const SizedBox(height: 16),
    const Text('Alarm Control',
        style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
    const SizedBox(height: 4),
    const Text('Smart Security System',
        style: TextStyle(color: Colors.white54, fontSize: 13)),
  ]);

  Widget _field(TextEditingController ctrl, String label, IconData icon, {
    bool obscure = false, TextInputType? type, Widget? suffix,
  }) =>
      TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: type,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          prefixIcon: Icon(icon, color: Colors.blue),
          suffixIcon: suffix,
          filled: true,
          fillColor: Colors.white.withOpacity(0.07),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.blue, width: 1.5),
          ),
        ),
      );

  Widget _primaryBtn(String label, VoidCallback onTap) => SizedBox(
    width: double.infinity,
    height: 52,
    child: ElevatedButton(
      onPressed: _loading ? null : onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 4,
      ),
      child: _loading
          ? const SizedBox(width: 22, height: 22,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
          : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    ),
  );

  Widget _linkBtn(String label, VoidCallback onTap) => TextButton(
    onPressed: onTap,
    child: Text(label, style: const TextStyle(color: Colors.blue, fontSize: 14)),
  );

  Widget _card(List<Widget> children) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.06),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(0.1)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: children),
  );

  // ── LOGIN PAGE ────────────────────────────────────────────────
  Widget _buildLogin() => Column(children: [
    _logo(),
    const SizedBox(height: 32),
    _card([
      const Text('Welcome Back',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 24),
      _field(_emailCtrl, 'Email', Icons.email_outlined, type: TextInputType.emailAddress),
      const SizedBox(height: 14),
      _field(_passCtrl, 'Password', Icons.lock_outline, obscure: _obscurePass,
          suffix: IconButton(
            icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
            onPressed: () => setState(() => _obscurePass = !_obscurePass),
          )),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: _linkBtn('Forgot Password?', () {
          _emailCtrl.clear();
          _switchPage(_AuthPage.forgotEmail);
        }),
      ),
      const SizedBox(height: 8),
      _primaryBtn('Login', _login),
    ]),
    const SizedBox(height: 20),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text("Don't have an account? ", style: TextStyle(color: Colors.white54)),
      _linkBtn('Register', () {
        _emailCtrl.clear(); _passCtrl.clear();
        _switchPage(_AuthPage.register);
      }),
    ]),
  ]);

  // ── REGISTER PAGE ─────────────────────────────────────────────
  Widget _buildRegister() => Column(children: [
    _logo(),
    const SizedBox(height: 32),
    _card([
      const Text('Create Account',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 24),
      _field(_nameCtrl,    'Full Name',        Icons.person_outline),
      const SizedBox(height: 14),
      _field(_emailCtrl,   'Email',            Icons.email_outlined, type: TextInputType.emailAddress),
      const SizedBox(height: 14),
      _field(_passCtrl,    'Password',         Icons.lock_outline, obscure: true),
      const SizedBox(height: 14),
      _field(_confirmCtrl, 'Confirm Password', Icons.lock_outline, obscure: true),
      const SizedBox(height: 20),
      _primaryBtn('Register', _register),
    ]),
    const SizedBox(height: 20),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text("Already have an account? ", style: TextStyle(color: Colors.white54)),
      _linkBtn('Login', () => _switchPage(_AuthPage.login)),
    ]),
  ]);

  // ── FORGOT PASSWORD — enter email ─────────────────────────────
  Widget _buildForgotEmail() => Column(children: [
    _logo(),
    const SizedBox(height: 32),
    _card([
      const Icon(Icons.lock_reset, color: Colors.blue, size: 48),
      const SizedBox(height: 12),
      const Text('Forgot Password',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('Enter your email and we will send\na 6-digit reset code.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 13)),
      const SizedBox(height: 24),
      _field(_emailCtrl, 'Email', Icons.email_outlined, type: TextInputType.emailAddress),
      const SizedBox(height: 20),
      _primaryBtn('Send Reset Code', _sendOtp),
    ]),
    const SizedBox(height: 20),
    _linkBtn('← Back to Login', () => _switchPage(_AuthPage.login)),
  ]);

  // ── OTP VERIFY ────────────────────────────────────────────────
  Widget _buildOtpVerify() => Column(children: [
    _logo(),
    const SizedBox(height: 32),
    _card([
      const Icon(Icons.mark_email_read_outlined, color: Colors.blue, size: 48),
      const SizedBox(height: 12),
      const Text('Enter Reset Code',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('A 6-digit code was sent to:\n$_otpEmail',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 13)),
      const SizedBox(height: 6),
      const Text('Check your Spam/Junk folder if not in inbox.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.orange, fontSize: 11)),
      const SizedBox(height: 20),
      // OTP input — numeric, max 6 digits
      TextField(
        controller: _otpCtrl,
        keyboardType: TextInputType.number,
        maxLength: 6,
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white, fontSize: 28,
            fontWeight: FontWeight.bold, letterSpacing: 12),
        decoration: InputDecoration(
          counterText: '',
          hintText: '------',
          hintStyle: TextStyle(color: Colors.white24, letterSpacing: 12, fontSize: 28),
          filled: true,
          fillColor: Colors.white.withOpacity(0.07),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.blue, width: 1.5),
          ),
        ),
      ),
      const SizedBox(height: 20),
      _primaryBtn('Verify Code', _verifyOtp),
      const SizedBox(height: 12),
      _linkBtn('Did not receive? Resend Code', _sendOtp),
    ]),
    const SizedBox(height: 20),
    _linkBtn('← Back', () {
      _otpCtrl.clear(); // clear OTP when going back
      _switchPage(_AuthPage.forgotEmail);
    }),
  ]);

  // ── RESET PASSWORD ────────────────────────────────────────────
  Widget _buildResetPassword() => Column(children: [
    _logo(),
    const SizedBox(height: 32),
    _card([
      const Icon(Icons.lock_open_outlined, color: Colors.green, size: 48),
      const SizedBox(height: 12),
      const Text('Set New Password',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 24),
      _field(_newPassCtrl, 'New Password', Icons.lock_outline, obscure: true),
      const SizedBox(height: 20),
      _primaryBtn('Reset Password', _resetPassword),
    ]),
  ]);
}

enum _AuthPage { login, register, forgotEmail, otpVerify, resetPassword }