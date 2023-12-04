import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:get/get.dart';

import '../consts.dart';
import './platform_model.dart';

enum SvcStatus { notReady, connecting, ready }

class StateGlobal {
  int _windowId = -1;
  final RxBool _fullscreen = false.obs;
  bool _isMinimized = false;
  final RxBool isMaximized = false.obs;
  final RxBool _showTabBar = true.obs;
  final RxDouble _resizeEdgeSize = RxDouble(kWindowEdgeSize);
  final RxDouble _windowBorderWidth = RxDouble(kWindowBorderWidth);
  final RxBool showRemoteToolBar = false.obs;
  final svcStatus = SvcStatus.notReady.obs;
  // Only used for macOS
  bool? closeOnFullscreen;

  String _inputSource = '';

  // Use for desktop -> remote toolbar -> resolution
  final Map<String, Map<int, String?>> _lastResolutionGroupValues = {};

  int get windowId => _windowId;
  RxBool get fullscreen => _fullscreen;
  bool get isMinimized => _isMinimized;
  double get tabBarHeight => fullscreen.isTrue ? 0 : kDesktopRemoteTabBarHeight;
  RxBool get showTabBar => _showTabBar;
  RxDouble get resizeEdgeSize => _resizeEdgeSize;
  RxDouble get windowBorderWidth => _windowBorderWidth;

  resetLastResolutionGroupValues(String peerId) {
    _lastResolutionGroupValues[peerId] = {};
  }

  setLastResolutionGroupValue(
      String peerId, int currentDisplay, String? value) {
    if (!_lastResolutionGroupValues.containsKey(peerId)) {
      _lastResolutionGroupValues[peerId] = {};
    }
    _lastResolutionGroupValues[peerId]![currentDisplay] = value;
  }

  String? getLastResolutionGroupValue(String peerId, int currentDisplay) {
    return _lastResolutionGroupValues[peerId]?[currentDisplay];
  }

  setWindowId(int id) => _windowId = id;
  setMaximized(bool v) {
    if (!_fullscreen.isTrue) {
      if (isMaximized.value != v) {
        isMaximized.value = v;
        _resizeEdgeSize.value =
            isMaximized.isTrue ? kMaximizeEdgeSize : kWindowEdgeSize;
      }
      if (!Platform.isMacOS) {
        _windowBorderWidth.value = v ? 0 : kWindowBorderWidth;
      }
    }
  }

  setMinimized(bool v) => _isMinimized = v;

  setFullscreen(bool v, {bool procWnd = true}) {
    if (_fullscreen.value != v) {
      _fullscreen.value = v;
      _showTabBar.value = !_fullscreen.value;
      _resizeEdgeSize.value = fullscreen.isTrue
          ? kFullScreenEdgeSize
          : isMaximized.isTrue
              ? kMaximizeEdgeSize
              : kWindowEdgeSize;
      print(
          "fullscreen: $fullscreen, resizeEdgeSize: ${_resizeEdgeSize.value}");
      _windowBorderWidth.value = fullscreen.isTrue ? 0 : kWindowBorderWidth;
      if (procWnd) {
        final wc = WindowController.fromWindowId(windowId);
        wc.setFullscreen(_fullscreen.isTrue).then((_) {
          // https://github.com/leanflutter/window_manager/issues/131#issuecomment-1111587982
          if (Platform.isWindows && !v) {
            Future.delayed(Duration.zero, () async {
              final frame = await wc.getFrame();
              final newRect = Rect.fromLTWH(
                  frame.left, frame.top, frame.width + 1, frame.height + 1);
              await wc.setFrame(newRect);
            });
          }
        });
      }
    }
  }

  String getInputSource({bool force = false}) {
    if (force || _inputSource.isEmpty) {
      _inputSource = bind.mainGetInputSource();
    }
    return _inputSource;
  }

  setInputSource(SessionID sessionId, String v) async {
    await bind.mainSetInputSource(sessionId: sessionId, value: v);
    _inputSource = bind.mainGetInputSource();
  }

  StateGlobal._();

  static final StateGlobal instance = StateGlobal._();
}

final stateGlobal = StateGlobal.instance;
