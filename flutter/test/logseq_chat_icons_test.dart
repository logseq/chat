import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/logseq_chat_icons.dart';

void main() {
  test('maps every app icon emitted by the LG view', () {
    final source = File('../shared/src/logseq_chat/view.cljc').readAsStringSync();
    final emittedNames = RegExp(r'"app:([a-z0-9]+(?:-[a-z0-9]+)*)"')
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toSet();

    expect(emittedNames, isNotEmpty);
    expect(
      logseqChatAppIcons.keys.toSet(),
      containsAll(emittedNames),
      reason: 'Every app:* icon must resolve to an Android Material icon.',
    );
    expect(logseqChatAppIcons.values, isNot(contains(Icons.question_mark)));
  });

  test('routes every literal LG icon through the cross-platform app map', () {
    final source = File('../shared/src/logseq_chat/view.cljc').readAsStringSync();
    final bareNames = RegExp(r':icon "(?!app:)([a-z0-9-]+)"')
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toSet();

    expect(
      bareNames,
      isEmpty,
      reason: 'Bare icon names bypass the Android Material icon policy.',
    );
  });

  test('uses distinct Material semantics for high-impact Android actions', () {
    expect(logseqChatAppIcons['sidebar-toggle'], Icons.menu_rounded);
    expect(logseqChatAppIcons['sync-status'], Icons.sync_rounded);
    expect(logseqChatAppIcons['task-backlog'], Icons.circle_outlined);
    expect(logseqChatAppIcons['task-review'], Icons.mark_chat_read_outlined);
    expect(
      logseqChatAppIcons['toolbar-copy-reference'],
      Icons.data_object_rounded,
    );
    expect(logseqChatAppIcons['toolbar-copy-url'], Icons.link_rounded);
    expect(logseqChatAppIcons['toolbar-unselect'], Icons.deselect_rounded);
    expect(logseqChatAppIcons['add'], Icons.add_rounded);
    expect(logseqChatAppIcons['arrow-up'], Icons.arrow_upward_rounded);
    expect(logseqChatAppIcons['arrow-down'], Icons.arrow_downward_rounded);
    expect(logseqChatAppIcons['chevron-right'], Icons.chevron_right_rounded);
    expect(logseqChatAppIcons['selected'], Icons.check_circle_rounded);
    expect(
      logseqChatAppIcons['unselected'],
      Icons.radio_button_unchecked_rounded,
    );
    expect(logseqChatAppIcons['trash'], Icons.delete_outline_rounded);
    expect(logseqChatAppIcons['search'], Icons.search_rounded);
    expect(logseqChatAppIcons['send'], Icons.send_rounded);
    expect(logseqChatAppIcons['download'], Icons.download_outlined);
    expect(logseqChatAppIcons['open-external'], Icons.open_in_new_rounded);
    expect(logseqChatAppIcons['refresh'], Icons.refresh_rounded);
    expect(logseqChatAppIcons['sign-out'], Icons.logout_rounded);
    expect(logseqChatAppIcons['terminal'], Icons.terminal_rounded);
    expect(logseqChatAppIcons['warning'], Icons.warning_amber_rounded);
    expect(logseqChatAppIcons['document'], Icons.article_outlined);
    expect(logseqChatAppIcons['folder'], Icons.hub_outlined);
    expect(logseqChatAppIcons['graph-local'], Icons.storage_rounded);
    expect(logseqChatAppIcons['task-doing'], Icons.donut_large_rounded);
    expect(logseqChatAppIcons['task-done'], Icons.check_circle_outline_rounded);
    expect(logseqChatAppIcons['task-review'], Icons.mark_chat_read_outlined);
    expect({
      logseqChatAppIcons['toolbar-copy-reference'],
      logseqChatAppIcons['toolbar-copy-url'],
    }, hasLength(2));
  });
}
