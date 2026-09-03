import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'login_screen.dart';
import 'favourite_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );
    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );
    _startSplash();
  }

  Future<void> _startSplash() async {
    _animationController.forward();
    await Future.delayed(const Duration(milliseconds: 2500));

    await AuthService().loadSession();
    if (!mounted) return;

    if (AuthService().isLoggedIn) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const FavoritesScreen()),
      );
    } else {
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
      // CHANGED: white background instead of dark
      backgroundColor: Colors.white,
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
                    Image.asset(
                      'assets/monsow_logo.jpg',
                      width: 220,
                      height: 100,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 30),
                    const Text(
                      'Monsow Alarm',
                      // CHANGED: dark text for white background
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Smart Security System',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 16,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 40),
                    const CircularProgressIndicator(
                      // CHANGED: use a darker/brand color on white
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
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
          child: const Text(
            'Version 1.0.0',
            textAlign: TextAlign.center,
            style: TextStyle(
              // CHANGED: lighter grey on white
              color: Colors.black38,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}