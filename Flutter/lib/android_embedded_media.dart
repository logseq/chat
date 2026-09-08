import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

typedef AndroidWebViewBuilder = Widget Function(Uri uri);

Uri? androidEmbeddedMediaUri(String value, {int? startSeconds}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final isYouTube =
      host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com');
  if (!isYouTube) return uri;

  String? videoId;
  if (host == 'youtu.be') {
    videoId = uri.pathSegments.firstOrNull;
  } else if (uri.pathSegments.firstOrNull == 'embed') {
    videoId = uri.pathSegments.elementAtOrNull(1);
  } else if (uri.path == '/watch') {
    videoId = uri.queryParameters['v'];
  }
  if (videoId == null || !RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(videoId)) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: 'www.youtube-nocookie.com',
    pathSegments: ['embed', videoId],
    queryParameters: {
      'playsinline': '1',
      if (startSeconds != null && startSeconds > 0) 'start': '$startSeconds',
    },
  );
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;

  T? elementAtOrNull(int index) =>
      index < 0 || index >= length ? null : this[index];
}

final class AndroidEmbeddedMedia extends StatefulWidget {
  const AndroidEmbeddedMedia({
    super.key,
    required this.url,
    this.startSeconds,
    this.isVideo = true,
    this.webViewBuilder,
  });

  final String url;
  final int? startSeconds;
  final bool isVideo;
  final AndroidWebViewBuilder? webViewBuilder;

  @override
  State<AndroidEmbeddedMedia> createState() => _AndroidEmbeddedMediaState();
}

final class _AndroidEmbeddedMediaState extends State<AndroidEmbeddedMedia> {
  var _loaded = false;

  Uri? get _uri =>
      androidEmbeddedMediaUri(widget.url, startSeconds: widget.startSeconds);

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    if (uri == null) {
      return Text(
        widget.isVideo ? 'Invalid video URL' : 'Invalid embed URL',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    if (_loaded) {
      return Semantics(
        key: const ValueKey('media.webview.loaded'),
        identifier: 'media.webview.loaded',
        container: true,
        child: SizedBox(
          height: 220,
          width: double.infinity,
          child: widget.webViewBuilder?.call(uri) ?? _AndroidWebView(uri: uri),
        ),
      );
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('button.media.load'),
        onTap: () => setState(() => _loaded = true),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 132),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  widget.isVideo
                      ? Icons.play_circle_outline_rounded
                      : Icons.web_asset_rounded,
                  size: 36,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isVideo ? 'Video preview' : 'Embedded content',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        uri.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap to load',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _AndroidWebView extends StatefulWidget {
  const _AndroidWebView({required this.uri});

  final Uri uri;

  @override
  State<_AndroidWebView> createState() => _AndroidWebViewState();
}

final class _AndroidWebViewState extends State<_AndroidWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null && {'http', 'https'}.contains(uri.scheme)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(widget.uri, headers: _headers(widget.uri));
  }

  @override
  void didUpdateWidget(covariant _AndroidWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _controller.loadRequest(widget.uri, headers: _headers(widget.uri));
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  Map<String, String> _headers(Uri uri) =>
      uri.host.endsWith('youtube-nocookie.com')
      ? const {'Referer': 'https://logseq.com/'}
      : const {};
}
