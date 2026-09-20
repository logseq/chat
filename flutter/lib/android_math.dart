import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

final class AndroidMath extends StatelessWidget {
  const AndroidMath({super.key, required this.expression});

  final String expression;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('math.rendered'),
    identifier: 'block.rich.math.rendered',
    container: true,
    label: 'Math: $expression',
    child: ExcludeSemantics(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Math.tex(
            expression,
            mathStyle: MathStyle.display,
            textStyle: Theme.of(context).textTheme.bodyLarge,
            onErrorFallback: (_) => Text(
              expression,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ),
    ),
  );
}
