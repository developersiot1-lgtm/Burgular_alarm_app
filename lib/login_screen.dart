import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'favourite_screen.dart';

// ================================================================
// login_screen.dart — WHITE THEME
// White background, black text, blue accents
// ================================================================

enum _AuthPage { login, register, forgotPassword, otpVerify, resetPassword }

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  _AuthPage _page = _AuthPage.login;

  final _nameCtrl    = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _passCtrl    = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _otpCtrl     = TextEditingController();
  final _newPassCtrl = TextEditingController();

  bool   _loading     = false;
  bool   _obscurePass = true;
  String _otpEmail    = '';

  late AnimationController _anim;
  late Animation<double>   _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeIn);
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    for (final c in [_nameCtrl, _emailCtrl, _passCtrl, _confirmCtrl, _otpCtrl, _newPassCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _switchPage(_AuthPage page) {
    _anim.reset();
    setState(() => _page = page);
    _anim.forward();
  }

  void _goHome() => Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const FavoritesScreen()));

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text.trim();
    if (email.isEmpty || pass.isEmpty) {
      _showSnack('Enter email and password', error: true); return;
    }
    setState(() => _loading = true);
    final res = await AuthService().login(email: email, password: pass);
    setState(() => _loading = false);
    res.success ? _goHome() : _showSnack(res.message, error: true);
  }

  Future<void> _register() async {
    final name    = _nameCtrl.text.trim();
    final email   = _emailCtrl.text.trim();
    final pass    = _passCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();
    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      _showSnack('All fields required', error: true); return;
    }
    if (pass != confirm) {
      _showSnack('Passwords do not match', error: true); return;
    }
    if (pass.length < 6) {
      _showSnack('Password must be at least 6 characters', error: true); return;
    }
    setState(() => _loading = true);
    final res = await AuthService().register(name: name, email: email, password: pass);
    setState(() => _loading = false);
    res.success ? _goHome() : _showSnack(res.message, error: true);
  }

  Future<void> _sendOtp() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) { _showSnack('Enter your email', error: true); return; }
    setState(() => _loading = true);
    final res = await AuthService().forgotPassword(email);
    setState(() => _loading = false);
    if (res.success) {
      _otpEmail = email;
      _otpCtrl.clear();
      _showSnack(res.message);
      _switchPage(_AuthPage.otpVerify);
    } else {
      _showSnack(res.message, error: true);
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpCtrl.text.trim().replaceAll(' ', '');
    if (otp.length != 6) {
      _showSnack('Enter the 6-digit code', error: true); return;
    }
    setState(() => _loading = true);
    final res = await AuthService().verifyOtp(_otpEmail, otp);
    setState(() => _loading = false);
    if (res.success) {
      _switchPage(_AuthPage.resetPassword);
    } else {
      _showSnack(res.message, error: true);
    }
  }

  Future<void> _resetPassword() async {
    final newPass = _newPassCtrl.text.trim();
    final otp     = _otpCtrl.text.trim().replaceAll(' ', '');
    if (newPass.length < 6) {
      _showSnack('Password must be at least 6 characters', error: true); return;
    }
    setState(() => _loading = true);
    final res = await AuthService().resetPassword(
        email: _otpEmail, otp: otp, newPassword: newPass);
    setState(() => _loading = false);
    if (res.success) {
      _showSnack('Password reset! Please login.');
      _switchPage(_AuthPage.login);
    } else {
      _showSnack(res.message, error: true);
    }
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: FadeTransition(
              opacity: _fade,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ── Logo ──────────────────────────────────────
                  Image.asset('assets/monsow_logo.jpg',
                      width: 180, height: 80, fit: BoxFit.contain),
                  const SizedBox(height: 8),
                  const Text('Monsow Alarm',
                      style: TextStyle(
                          color: Colors.black,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                  const Text('Smart Security System',
                      style: TextStyle(color: Colors.black54, fontSize: 14)),
                  const SizedBox(height: 36),

                  // ── Card ──────────────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 20,
                            offset: const Offset(0, 4)),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: _buildPageContent(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageContent() {
    switch (_page) {
      case _AuthPage.login:          return _buildLogin();
      case _AuthPage.register:       return _buildRegister();
      case _AuthPage.forgotPassword: return _buildForgot();
      case _AuthPage.otpVerify:      return _buildOtp();
      case _AuthPage.resetPassword:  return _buildReset();
    }
  }

  // ─── Shared widget helpers ─────────────────────────────────────────────────

  Widget _title(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Text(text,
        style: const TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.bold)),
  );

  Widget _field(TextEditingController ctrl,
      {required String label,
        bool obscure = false,
        TextInputType? keyboard,
        Widget? suffix}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: ctrl,
          obscureText: obscure,
          keyboardType: keyboard,
          style: const TextStyle(color: Colors.black),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: Colors.black54),
            filled: true,
            fillColor: const Color(0xFFF5F5F5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            suffixIcon: suffix,
          ),
        ),
      );

  Widget _primaryBtn(String label, VoidCallback action) => SizedBox(
    width: double.infinity,
    height: 50,
    child: ElevatedButton(
      onPressed: _loading ? null : action,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _loading
          ? const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.white))
          : Text(label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    ),
  );

  Widget _linkBtn(String label, VoidCallback onTap) => TextButton(
      onPressed: onTap,
      child: Text(label, style: const TextStyle(color: Colors.blue)));

  // ─── Login ────────────────────────────────────────────────────────────────

  Widget _buildLogin() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _title('Sign In'),
    _field(_emailCtrl, label: 'Email', keyboard: TextInputType.emailAddress),
    _field(_passCtrl,
        label: 'Password',
        obscure: _obscurePass,
        suffix: IconButton(
          icon: Icon(
              _obscurePass ? Icons.visibility_off : Icons.visibility,
              color: Colors.black38),
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
        )),
    _primaryBtn('Sign In', _login),
    const SizedBox(height: 12),
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      _linkBtn('Create account', () => _switchPage(_AuthPage.register)),
      _linkBtn('Forgot password?', () => _switchPage(_AuthPage.forgotPassword)),
    ]),
  ]);

  // ─── Register ─────────────────────────────────────────────────────────────

  Widget _buildRegister() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _title('Create Account'),
    _field(_nameCtrl, label: 'Full Name'),
    _field(_emailCtrl, label: 'Email', keyboard: TextInputType.emailAddress),
    _field(_passCtrl, label: 'Password', obscure: _obscurePass,
        suffix: IconButton(
          icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility,
              color: Colors.black38),
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
        )),
    _field(_confirmCtrl, label: 'Confirm Password', obscure: true),
    _primaryBtn('Create Account', _register),
    const SizedBox(height: 8),
    Center(child: _linkBtn('Already have an account? Sign in',
            () => _switchPage(_AuthPage.login))),
  ]);

  // ─── Forgot ───────────────────────────────────────────────────────────────

  Widget _buildForgot() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _title('Forgot Password'),
    const Text('Enter your email to receive a reset code.',
        style: TextStyle(color: Colors.black54)),
    const SizedBox(height: 16),
    _field(_emailCtrl, label: 'Email', keyboard: TextInputType.emailAddress),
    _primaryBtn('Send Reset Code', _sendOtp),
    const SizedBox(height: 8),
    Center(child: _linkBtn('Back to Sign In', () => _switchPage(_AuthPage.login))),
  ]);

  // ─── OTP ──────────────────────────────────────────────────────────────────

  Widget _buildOtp() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _title('Enter OTP'),
    Text('Code sent to $_otpEmail',
        style: const TextStyle(color: Colors.black54)),
    const SizedBox(height: 16),
    _field(_otpCtrl,
        label: '6-digit code', keyboard: TextInputType.number),
    _primaryBtn('Verify Code', _verifyOtp),
    const SizedBox(height: 8),
    Center(child: _linkBtn('Resend code', _sendOtp)),
  ]);

  // ─── Reset ────────────────────────────────────────────────────────────────

  Widget _buildReset() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _title('Reset Password'),
    _field(_newPassCtrl, label: 'New Password', obscure: true),
    _primaryBtn('Reset Password', _resetPassword),
    const SizedBox(height: 8),
    Center(child: _linkBtn('Back to Sign In', () => _switchPage(_AuthPage.login))),
  ]);
}