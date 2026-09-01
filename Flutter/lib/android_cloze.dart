import 'package:flutter/material.dart';

final class AndroidCloze extends StatefulWidget {
  const AndroidCloze({super.key, required this.text});

  final String text;

  @override
  State<AndroidCloze> createState() => _AndroidClozeState();
}

final class _AndroidClozeState extends State<AndroidCloze> {
  var _revealed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: 'block.rich.cloze.reveal',
    label: _revealed ? widget.text : 'Reveal cloze',
    button: true,
    child: ActionChip(
      key: const ValueKey('button.cloze.reveal'),
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        _revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 18,
      ),
      label: Text(_revealed ? widget.text : 'Tap to reveal'),
      onPressed: () => setState(() => _revealed = !_revealed),
    ),
  );
}
