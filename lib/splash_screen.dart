import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'login_screen.dart';
import 'favourite_screen.dart';

// ================================================================
// splash_screen.dart  (UPDATED)
// Checks saved login session → routes to Login or FavoritesScreen
// ================================================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double>   _fadeAnimation;
  late Animation<double>   _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController,
          curve: const Interval(0.0, 0.5, curve: Curves.easeIn)),
    );
    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _animationController,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut)),
    );
    _startSplash();
  }

  Future<void> _startSplash() async {
    _animationController.forward();
    await Future.delayed(const Duration(milliseconds: 2500));

    // ── Check if user is already logged in ──────────────────────
    await AuthService().loadSession();

    if (!mounted) return;

    if (AuthService().isLoggedIn) {
      // Already logged in — go straight to devices list
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const FavoritesScreen()),
      );
    } else {
      // Not logged in — show login screen
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Center(
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 120, height: 120,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [Colors.blue, Colors.blue.shade700]),
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(
                          color: Colors.blue.withOpacity(0.3),
                          blurRadius: 30, spreadRadius: 10,
                        )],
                      ),
                      child: const Icon(Icons.security, size: 60, color: Colors.white),
                    ),
                    const SizedBox(height: 30),
                    const Text('Alarm Control',
                        style: TextStyle(color: Colors.white, fontSize: 32,
                            fontWeight: FontWeight.bold, letterSpacing: 2)),
                    const SizedBox(height: 10),
                    const Text('Smart Security System',
                        style: TextStyle(color: Colors.white70, fontSize: 16, letterSpacing: 1)),
                    const SizedBox(height: 40),
                    const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blue)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.only(bottom: 20),
        color: Colors.transparent,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: const Text('Version 1.0.0',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ),
      ),
    );
  }
}