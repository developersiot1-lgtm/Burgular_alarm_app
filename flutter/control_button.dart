import 'package:flutter/material.dart';

class ControlButton extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color color;
  final bool isActive;
  final VoidCallback onPressed;

  const ControlButton({
    Key? key,
    required this.title,
    required this.icon,
    required this.color,
    required this.isActive,
    required this.onPressed,
  }) : super(key: key);

  @override
  _ControlButtonState createState() => _ControlButtonState();
}

class _ControlButtonState extends State<ControlButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
    _animationController.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    _animationController.reverse();
    widget.onPressed();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
    _animationController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Container(
              decoration: BoxDecoration(
                color: widget.isActive
                    ? widget.color.withOpacity(0.3)
                    : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.isActive
                      ? widget.color
                      : Colors.white.withOpacity(0.2),
                  width: 2,
                ),
                boxShadow: widget.isActive
                    ? [
                  BoxShadow(
                    color: widget.color.withOpacity(0.3),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.icon,
                    size: 32,
                    color: widget.isActive ? widget.color : Colors.white70,
                  ),
                  SizedBox(height: 8),
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: widget.isActive ? widget.color : Colors.white70,
                    ),
                  ),
                  if (widget.isActive) ...[
                    SizedBox(height: 4),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: widget.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}