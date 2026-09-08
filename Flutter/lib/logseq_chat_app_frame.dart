import 'package:flutter/material.dart';

final class LogseqChatAppFrame extends StatelessWidget {
  const LogseqChatAppFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: child));
}
