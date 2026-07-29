import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A no-op WebViewPlatform for widget tests.
///
/// Since Phase 15.1 every story opens in [BrowserScreen], so any test that
/// follows a story to the end now builds a WebViewController — which asserts
/// unless a platform implementation is registered, and there is none under
/// `flutter test`. This fake registers one that renders an empty box and
/// remembers the last requested URL, so the navigation itself stays testable
/// without pretending to run a real browser engine.
class FakeWebViewPlatform extends WebViewPlatform {
  /// Installs this fake as the platform implementation. Call once from
  /// setUpAll (or the top of a test) before any BrowserScreen is built.
  static FakeWebViewPlatform install() {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    return platform;
  }

  /// The last URL a controller was asked to load.
  String? lastRequestedUrl;

  @override
  PlatformWebViewController createPlatformWebViewController(
      PlatformWebViewControllerCreationParams params) {
    return _FakeController(params, this);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
      PlatformNavigationDelegateCreationParams params) {
    return _FakeNavigationDelegate(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
      PlatformWebViewWidgetCreationParams params) {
    return _FakeWidget(params);
  }

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
      PlatformWebViewCookieManagerCreationParams params) {
    return _FakeCookieManager(params);
  }
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this._platform) : super.implementation();

  final FakeWebViewPlatform _platform;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  _FakeNavigationDelegate? _delegate;

  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {
    _delegate = handler as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    final url = params.uri.toString();
    _platform.lastRequestedUrl = url;
    // Land the page straight away: a real engine would take time, but a test
    // that waits for an overlay which never clears just times out.
    _delegate?.onProgress?.call(100);
    _delegate?.onPageFinished?.call(url);
  }

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  void Function(int progress)? onProgress;
  void Function(String url)? onPageFinished;

  @override
  Future<void> setOnProgress(void Function(int progress) onProgress) async {
    this.onProgress = onProgress;
  }

  @override
  Future<void> setOnPageFinished(void Function(String url) onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnPageStarted(void Function(String url) onPageStarted) async {}

  @override
  Future<void> setOnWebResourceError(
      void Function(WebResourceError error) onWebResourceError) async {}

  @override
  Future<void> setOnNavigationRequest(
      FutureOr<NavigationDecision> Function(NavigationRequest request)
          onNavigationRequest) async {}
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _FakeCookieManager extends PlatformWebViewCookieManager {
  _FakeCookieManager(super.params) : super.implementation();
}
