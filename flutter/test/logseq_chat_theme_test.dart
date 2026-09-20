import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/logseq_chat_theme.dart';

void main() {
  for (final theme in [LogseqChatTheme.light(), LogseqChatTheme.dark()]) {
    test(
      'navigation and secondary controls stay neutral in ${theme.brightness}',
      () {
        expect(
          theme.colorScheme.secondaryContainer,
          theme.colorScheme.surfaceContainerHighest,
        );
        expect(
          theme.colorScheme.onSecondaryContainer,
          theme.colorScheme.onSurface,
        );
        expect(
          theme.textButtonTheme.style?.foregroundColor?.resolve({}),
          theme.colorScheme.onSurface,
        );
        expect(theme.colorScheme.primary, isNot(theme.colorScheme.onSurface));
      },
    );
  }

  test('uses a complete Material 3 surface and typography hierarchy', () {
    final theme = LogseqChatTheme.light();

    expect(theme.useMaterial3, isTrue);
    expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
    expect(theme.colorScheme.surface, isNot(const Color(0xffffffff)));
    expect(
      theme.colorScheme.surfaceContainerLow,
      isNot(theme.colorScheme.surface),
    );
    expect(theme.textTheme.headlineLarge?.fontWeight, FontWeight.w600);
    expect(theme.textTheme.titleLarge?.fontWeight, FontWeight.w600);
    expect(theme.textTheme.bodyLarge?.height, greaterThanOrEqualTo(1.4));
    expect(theme.textTheme.labelLarge?.fontWeight, FontWeight.w600);
  });

  test('gives Android controls consistent shapes and 48dp touch targets', () {
    final theme = LogseqChatTheme.light();
    final states = <WidgetState>{};

    expect(
      theme.filledButtonTheme.style?.minimumSize?.resolve(states),
      const Size(64, 48),
    );
    expect(
      theme.outlinedButtonTheme.style?.minimumSize?.resolve(states),
      const Size(64, 48),
    );
    expect(
      theme.iconButtonTheme.style?.minimumSize?.resolve(states),
      const Size.square(48),
    );
    expect(
      theme.filledButtonTheme.style?.shape?.resolve(states),
      isA<StadiumBorder>(),
    );
    expect(theme.inputDecorationTheme.filled, isTrue);
    final border = theme.inputDecorationTheme.border as OutlineInputBorder;
    expect(border.borderSide, BorderSide.none);
    expect(border.borderRadius.topLeft.x, 20);
  });

  test('styles app chrome as tonal Material surfaces', () {
    final theme = LogseqChatTheme.light();

    expect(theme.appBarTheme.elevation, 0);
    expect(theme.appBarTheme.scrolledUnderElevation, 0);
    expect(
      theme.drawerTheme.backgroundColor,
      theme.colorScheme.surfaceContainerLow,
    );
    expect(theme.drawerTheme.width, 320);
    final drawerShape = theme.drawerTheme.shape as RoundedRectangleBorder;
    expect(
      drawerShape.borderRadius,
      const BorderRadius.horizontal(right: Radius.circular(28)),
    );
    final sheetShape = theme.bottomSheetTheme.shape as RoundedRectangleBorder;
    expect(
      sheetShape.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(28)),
    );
    final cardShape = theme.cardTheme.shape as RoundedRectangleBorder;
    expect(cardShape.borderRadius, BorderRadius.circular(24));
  });

  test('dark mode retains distinct tonal surfaces', () {
    final theme = LogseqChatTheme.dark();

    expect(theme.brightness, Brightness.dark);
    expect(
      theme.colorScheme.surfaceContainerLow,
      isNot(theme.colorScheme.surface),
    );
    expect(
      theme.colorScheme.onSurface,
      isNot(theme.colorScheme.onSurfaceVariant),
    );
  });
}
