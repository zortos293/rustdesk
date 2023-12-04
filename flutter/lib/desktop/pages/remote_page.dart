import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart'
    as custom_cursor_manager;
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_custom_cursor/flutter_custom_cursor.dart';
import 'package:flutter_improved_scrolling/flutter_improved_scrolling.dart';

import '../../consts.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/remote_input.dart';
import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/toolbar.dart';
import '../../models/model.dart';
import '../../models/desktop_render_texture.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';
import '../../utils/image.dart';
import '../widgets/remote_toolbar.dart';
import '../widgets/kb_layout_type_chooser.dart';
import '../widgets/tabbar_widget.dart';

final SimpleWrapper<bool> _firstEnterImage = SimpleWrapper(false);

// Used to skip session close if "move to new window" is clicked.
final Map<String, bool> closeSessionOnDispose = {};

class RemotePage extends StatefulWidget {
  RemotePage({
    Key? key,
    required this.id,
    required this.sessionId,
    required this.tabWindowId,
    required this.display,
    required this.displays,
    required this.password,
    required this.toolbarState,
    required this.tabController,
    this.switchUuid,
    this.forceRelay,
  }) : super(key: key);

  final String id;
  final SessionID? sessionId;
  final int? tabWindowId;
  final int? display;
  final List<int>? displays;
  final String? password;
  final ToolbarState toolbarState;
  final String? switchUuid;
  final bool? forceRelay;
  final SimpleWrapper<State<RemotePage>?> _lastState = SimpleWrapper(null);
  final DesktopTabController tabController;

  FFI get ffi => (_lastState.value! as _RemotePageState)._ffi;

  @override
  State<RemotePage> createState() {
    final state = _RemotePageState();
    _lastState.value = state;
    return state;
  }
}

class _RemotePageState extends State<RemotePage>
    with AutomaticKeepAliveClientMixin, MultiWindowListener {
  Timer? _timer;
  String keyboardMode = "legacy";
  bool _isWindowBlur = false;
  final _cursorOverImage = false.obs;
  late RxBool _showRemoteCursor;
  late RxBool _zoomCursor;
  late RxBool _remoteCursorMoved;
  late RxBool _keyboardEnabled;
  final Map<int, RenderTexture> _renderTextures = {};

  var _blockableOverlayState = BlockableOverlayState();

  final FocusNode _rawKeyFocusNode = FocusNode(debugLabel: "rawkeyFocusNode");

  Function(bool)? _onEnterOrLeaveImage4Toolbar;

  late FFI _ffi;

  SessionID get sessionId => _ffi.sessionId;

  void _initStates(String id) {
    initSharedStates(id);
    _zoomCursor = PeerBoolOption.find(id, 'zoom-cursor');
    _showRemoteCursor = ShowRemoteCursorState.find(id);
    _keyboardEnabled = KeyboardEnabledState.find(id);
    _remoteCursorMoved = RemoteCursorMovedState.find(id);
  }

  @override
  void initState() {
    super.initState();
    _initStates(widget.id);
    _ffi = FFI(widget.sessionId);
    Get.put(_ffi, tag: widget.id);
    _ffi.imageModel.addCallbackOnFirstImage((String peerId) {
      showKBLayoutTypeChooserIfNeeded(
          _ffi.ffiModel.pi.platform, _ffi.dialogManager);
    });
    _ffi.start(
      widget.id,
      password: widget.password,
      switchUuid: widget.switchUuid,
      forceRelay: widget.forceRelay,
      tabWindowId: widget.tabWindowId,
      display: widget.display,
      displays: widget.displays,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    if (!Platform.isLinux) {
      WakelockPlus.enable();
    }

    _ffi.ffiModel.updateEventListener(sessionId, widget.id);
    bind.pluginSyncUi(syncTo: kAppTypeDesktopRemote);
    _ffi.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    // Session option should be set after models.dart/FFI.start
    _showRemoteCursor.value = bind.sessionGetToggleOptionSync(
        sessionId: sessionId, arg: 'show-remote-cursor');
    _zoomCursor.value = bind.sessionGetToggleOptionSync(
        sessionId: sessionId, arg: 'zoom-cursor');
    DesktopMultiWindow.addListener(this);
    // if (!_isCustomCursorInited) {
    //   customCursorController.registerNeedUpdateCursorCallback(
    //       (String? lastKey, String? currentKey) async {
    //     if (_firstEnterImage.value) {
    //       _firstEnterImage.value = false;
    //       return true;
    //     }
    //     return lastKey == null || lastKey != currentKey;
    //   });
    //   _isCustomCursorInited = true;
    // }

    _blockableOverlayState.applyFfi(_ffi);
    widget.tabController.onSelected?.call(widget.id);
  }

  @override
  void onWindowBlur() {
    super.onWindowBlur();
    // On windows, we use `focus` way to handle keyboard better.
    // Now on Linux, there's some rdev issues which will break the input.
    // We disable the `focus` way for non-Windows temporarily.
    if (Platform.isWindows) {
      _isWindowBlur = true;
      // unfocus the primary-focus when the whole window is lost focus,
      // and let OS to handle events instead.
      _rawKeyFocusNode.unfocus();
    }
  }

  @override
  void onWindowFocus() {
    super.onWindowFocus();
    // See [onWindowBlur].
    if (Platform.isWindows) {
      _isWindowBlur = false;
    }
  }

  @override
  void onWindowRestore() {
    super.onWindowRestore();
    // On windows, we use `onWindowRestore` way to handle window restore from
    // a minimized state.
    if (Platform.isWindows) {
      _isWindowBlur = false;
    }
    if (!Platform.isLinux) {
      WakelockPlus.enable();
    }
  }

  // When the window is unminimized, onWindowMaximize or onWindowRestore can be called when the old state was maximized or not.
  @override
  void onWindowMaximize() {
    super.onWindowMaximize();
    if (!Platform.isLinux) {
      WakelockPlus.enable();
    }
  }

  @override
  void onWindowMinimize() {
    super.onWindowMinimize();
    if (!Platform.isLinux) {
      WakelockPlus.disable();
    }
  }

  @override
  Future<void> dispose() async {
    final closeSession = closeSessionOnDispose.remove(widget.id) ?? true;

    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    debugPrint("REMOTE PAGE dispose session $sessionId ${widget.id}");
    for (final texture in _renderTextures.values) {
      await texture.destroy(closeSession);
    }
    // ensure we leave this session, this is a double check
    _ffi.inputModel.enterOrLeave(false);
    DesktopMultiWindow.removeListener(this);
    _ffi.dialogManager.hideMobileActionsOverlay();
    _ffi.recordingModel.onClose();
    _rawKeyFocusNode.dispose();
    await _ffi.close(closeSession: closeSession);
    _timer?.cancel();
    _ffi.dialogManager.dismissAll();
    if (closeSession) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
    }
    if (!Platform.isLinux) {
      await WakelockPlus.disable();
    }
    await Get.delete<FFI>(tag: widget.id);
    removeSharedStates(widget.id);
  }

  Widget emptyOverlay() => BlockableOverlay(
        /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
        /// see override build() in [BlockableOverlay]
        state: _blockableOverlayState,
        underlying: Container(
          color: Colors.transparent,
        ),
      );

  Widget buildBody(BuildContext context) {
    remoteToolbar(BuildContext context) => RemoteToolbar(
          id: widget.id,
          ffi: _ffi,
          state: widget.toolbarState,
          onEnterOrLeaveImageSetter: (func) =>
              _onEnterOrLeaveImage4Toolbar = func,
          onEnterOrLeaveImageCleaner: () => _onEnterOrLeaveImage4Toolbar = null,
          setRemoteState: setState,
        );

    bodyWidget() {
      return Stack(
        children: [
          Container(
              color: Colors.black,
              child: RawKeyFocusScope(
                  focusNode: _rawKeyFocusNode,
                  onFocusChange: (bool imageFocused) {
                    debugPrint(
                        "onFocusChange(window active:${!_isWindowBlur}) $imageFocused");
                    // See [onWindowBlur].
                    if (Platform.isWindows) {
                      if (_isWindowBlur) {
                        imageFocused = false;
                        Future.delayed(Duration.zero, () {
                          _rawKeyFocusNode.unfocus();
                        });
                      }
                      if (imageFocused) {
                        _ffi.inputModel.enterOrLeave(true);
                      } else {
                        _ffi.inputModel.enterOrLeave(false);
                      }
                    }
                  },
                  inputModel: _ffi.inputModel,
                  child: getBodyForDesktop(context))),
          Stack(
            children: [
              _ffi.ffiModel.pi.isSet.isTrue &&
                      _ffi.ffiModel.waitForFirstImage.isTrue
                  ? emptyOverlay()
                  : () {
                      _ffi.ffiModel.tryShowAndroidActionsOverlay();
                      return Offstage();
                    }(),
              // Use Overlay to enable rebuild every time on menu button click.
              _ffi.ffiModel.pi.isSet.isTrue
                  ? Overlay(
                      initialEntries: [OverlayEntry(builder: remoteToolbar)])
                  : remoteToolbar(context),
              _ffi.ffiModel.pi.isSet.isFalse ? emptyOverlay() : Offstage(),
            ],
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Obx(() {
        final imageReady = _ffi.ffiModel.pi.isSet.isTrue &&
            _ffi.ffiModel.waitForFirstImage.isFalse;
        if (imageReady) {
          // If the privacy mode(disable physical displays) is switched,
          // we should not dismiss the dialog immediately.
          if (DateTime.now().difference(togglePrivacyModeTime) >
              const Duration(milliseconds: 3000)) {
            // `dismissAll()` is to ensure that the state is clean.
            // It's ok to call dismissAll() here.
            _ffi.dialogManager.dismissAll();
            // Recreate the block state to refresh the state.
            _blockableOverlayState = BlockableOverlayState();
            _blockableOverlayState.applyFfi(_ffi);
          }
          // Block the whole `bodyWidget()` when dialog shows.
          return BlockableOverlay(
            underlying: bodyWidget(),
            state: _blockableOverlayState,
          );
        } else {
          // `_blockableOverlayState` is not recreated here.
          // The toolbar's block state won't work properly when reconnecting, but that's okay.
          return bodyWidget();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return WillPopScope(
        onWillPop: () async {
          clientClose(sessionId, _ffi.dialogManager);
          return false;
        },
        child: MultiProvider(providers: [
          ChangeNotifierProvider.value(value: _ffi.ffiModel),
          ChangeNotifierProvider.value(value: _ffi.imageModel),
          ChangeNotifierProvider.value(value: _ffi.cursorModel),
          ChangeNotifierProvider.value(value: _ffi.canvasModel),
          ChangeNotifierProvider.value(value: _ffi.recordingModel),
        ], child: buildBody(context)));
  }

  void enterView(PointerEnterEvent evt) {
    _cursorOverImage.value = true;
    _firstEnterImage.value = true;
    if (_onEnterOrLeaveImage4Toolbar != null) {
      try {
        _onEnterOrLeaveImage4Toolbar!(true);
      } catch (e) {
        //
      }
    }
    // See [onWindowBlur].
    if (!Platform.isWindows) {
      if (!_rawKeyFocusNode.hasFocus) {
        _rawKeyFocusNode.requestFocus();
      }
      _ffi.inputModel.enterOrLeave(true);
    }
  }

  void leaveView(PointerExitEvent evt) {
    if (_ffi.ffiModel.keyboard) {
      _ffi.inputModel.tryMoveEdgeOnExit(evt.position);
    }

    _cursorOverImage.value = false;
    _firstEnterImage.value = false;
    if (_onEnterOrLeaveImage4Toolbar != null) {
      try {
        _onEnterOrLeaveImage4Toolbar!(false);
      } catch (e) {
        //
      }
    }
    // See [onWindowBlur].
    if (!Platform.isWindows) {
      _ffi.inputModel.enterOrLeave(false);
    }
  }

  Widget _buildRawTouchAndPointerRegion(
    Widget child,
    PointerEnterEventListener? onEnter,
    PointerExitEventListener? onExit,
  ) {
    return RawTouchGestureDetectorRegion(
      child: _buildRawPointerMouseRegion(child, onEnter, onExit),
      ffi: _ffi,
    );
  }

  Widget _buildRawPointerMouseRegion(
    Widget child,
    PointerEnterEventListener? onEnter,
    PointerExitEventListener? onExit,
  ) {
    return RawPointerMouseRegion(
      onEnter: onEnter,
      onExit: onExit,
      onPointerDown: (event) {
        // A double check for blur status.
        // Note: If there's an `onPointerDown` event is triggered, `_isWindowBlur` is expected being false.
        // Sometimes the system does not send the necessary focus event to flutter. We should manually
        // handle this inconsistent status by setting `_isWindowBlur` to false. So we can
        // ensure the grab-key thread is running when our users are clicking the remote canvas.
        if (_isWindowBlur) {
          debugPrint(
              "Unexpected status: onPointerDown is triggered while the remote window is in blur status");
          _isWindowBlur = false;
        }
        if (!_rawKeyFocusNode.hasFocus) {
          _rawKeyFocusNode.requestFocus();
        }
      },
      inputModel: _ffi.inputModel,
      child: child,
    );
  }

  Map<int, RenderTexture> _updateGetRenderTextures(int curDisplay) {
    tryCreateTexture(int idx) {
      if (!_renderTextures.containsKey(idx)) {
        final renderTexture = RenderTexture();
        _renderTextures[idx] = renderTexture;
        renderTexture.create(idx, sessionId);
      }
    }

    tryRemoveTexture(int idx) {
      if (_renderTextures.containsKey(idx)) {
        _renderTextures[idx]!.destroy(true);
        _renderTextures.remove(idx);
      }
    }

    if (curDisplay == kAllDisplayValue) {
      final displays = _ffi.ffiModel.pi.getCurDisplays();
      for (var i = 0; i < displays.length; i++) {
        tryCreateTexture(i);
      }
    } else {
      tryCreateTexture(curDisplay);
      for (var i = 0; i < _ffi.ffiModel.pi.displays.length; i++) {
        if (i != curDisplay) {
          tryRemoveTexture(i);
        }
      }
    }
    return _renderTextures;
  }

  Widget getBodyForDesktop(BuildContext context) {
    var paints = <Widget>[
      MouseRegion(onEnter: (evt) {
        bind.hostStopSystemKeyPropagate(stopped: false);
      }, onExit: (evt) {
        bind.hostStopSystemKeyPropagate(stopped: true);
      }, child: LayoutBuilder(builder: (context, constraints) {
        Future.delayed(Duration.zero, () {
          Provider.of<CanvasModel>(context, listen: false).updateViewStyle();
        });
        final peerDisplay = CurrentDisplayState.find(widget.id);
        return Obx(
          () => _ffi.ffiModel.pi.isSet.isFalse
              ? Container(color: Colors.transparent)
              : Obx(() => ImagePaint(
                    id: widget.id,
                    zoomCursor: _zoomCursor,
                    cursorOverImage: _cursorOverImage,
                    keyboardEnabled: _keyboardEnabled,
                    remoteCursorMoved: _remoteCursorMoved,
                    renderTextures: _updateGetRenderTextures(peerDisplay.value),
                    listenerBuilder: (child) => _buildRawTouchAndPointerRegion(
                        child, enterView, leaveView),
                  )),
        );
      }))
    ];

    if (!_ffi.canvasModel.cursorEmbedded) {
      paints.add(Obx(() => Offstage(
          offstage: _showRemoteCursor.isFalse || _remoteCursorMoved.isFalse,
          child: CursorPaint(
            id: widget.id,
            zoomCursor: _zoomCursor,
          ))));
    }
    paints.add(
      Positioned(
        top: 10,
        right: 10,
        child: _buildRawTouchAndPointerRegion(
            QualityMonitor(_ffi.qualityMonitorModel), null, null),
      ),
    );
    return Stack(
      children: paints,
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class ImagePaint extends StatefulWidget {
  final String id;
  final RxBool zoomCursor;
  final RxBool cursorOverImage;
  final RxBool keyboardEnabled;
  final RxBool remoteCursorMoved;
  final Map<int, RenderTexture> renderTextures;
  final Widget Function(Widget)? listenerBuilder;

  ImagePaint(
      {Key? key,
      required this.id,
      required this.zoomCursor,
      required this.cursorOverImage,
      required this.keyboardEnabled,
      required this.remoteCursorMoved,
      required this.renderTextures,
      this.listenerBuilder})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _ImagePaintState();
}

class _ImagePaintState extends State<ImagePaint> {
  bool _lastRemoteCursorMoved = false;

  String get id => widget.id;
  RxBool get zoomCursor => widget.zoomCursor;
  RxBool get cursorOverImage => widget.cursorOverImage;
  RxBool get keyboardEnabled => widget.keyboardEnabled;
  RxBool get remoteCursorMoved => widget.remoteCursorMoved;
  Widget Function(Widget)? get listenerBuilder => widget.listenerBuilder;

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    var c = Provider.of<CanvasModel>(context);
    final s = c.scale;

    bool isViewAdaptive() => c.viewStyle.style == kRemoteViewStyleAdaptive;
    bool isViewOriginal() => c.viewStyle.style == kRemoteViewStyleOriginal;

    mouseRegion({child}) => Obx(() {
          double getCursorScale() {
            var c = Provider.of<CanvasModel>(context);
            var cursorScale = 1.0;
            if (Platform.isWindows) {
              // debug win10
              if (zoomCursor.value && isViewAdaptive()) {
                cursorScale = s * c.devicePixelRatio;
              }
            } else {
              if (zoomCursor.value || isViewOriginal()) {
                cursorScale = s;
              }
            }
            return cursorScale;
          }

          return MouseRegion(
              cursor: cursorOverImage.isTrue
                  ? c.cursorEmbedded
                      ? SystemMouseCursors.none
                      : keyboardEnabled.isTrue
                          ? (() {
                              if (remoteCursorMoved.isTrue) {
                                _lastRemoteCursorMoved = true;
                                return SystemMouseCursors.none;
                              } else {
                                if (_lastRemoteCursorMoved) {
                                  _lastRemoteCursorMoved = false;
                                  _firstEnterImage.value = true;
                                }
                                return _buildCustomCursor(
                                    context, getCursorScale());
                              }
                            }())
                          : _buildDisabledCursor(context, getCursorScale())
                  : MouseCursor.defer,
              onHover: (evt) {},
              child: child);
        });

    if (c.imageOverflow.isTrue && c.scrollStyle == ScrollStyle.scrollbar) {
      final paintWidth = c.getDisplayWidth() * s;
      final paintHeight = c.getDisplayHeight() * s;
      final paintSize = Size(paintWidth, paintHeight);
      final paintWidget = useTextureRender
          ? _BuildPaintTextureRender(
              c, s, Offset.zero, paintSize, isViewOriginal())
          : _buildScrollbarNonTextureRender(m, paintSize, s);
      return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            c.updateScrollPercent();
            return false;
          },
          child: mouseRegion(
            child: Obx(() => _buildCrossScrollbarFromLayout(
                  context,
                  _buildListener(paintWidget),
                  c.size,
                  paintSize,
                  c.scrollHorizontal,
                  c.scrollVertical,
                )),
          ));
    } else {
      if (c.size.width > 0 && c.size.height > 0) {
        final paintWidget = useTextureRender
            ? _BuildPaintTextureRender(
                c,
                s,
                Offset(
                  Platform.isLinux ? c.x.toInt().toDouble() : c.x,
                  Platform.isLinux ? c.y.toInt().toDouble() : c.y,
                ),
                c.size,
                isViewOriginal())
            : _buildScrollAuthNonTextureRender(m, c, s);
        return mouseRegion(child: _buildListener(paintWidget));
      } else {
        return Container();
      }
    }
  }

  Widget _buildScrollbarNonTextureRender(
      ImageModel m, Size imageSize, double s) {
    return CustomPaint(
      size: imageSize,
      painter: ImagePainter(image: m.image, x: 0, y: 0, scale: s),
    );
  }

  Widget _buildScrollAuthNonTextureRender(
      ImageModel m, CanvasModel c, double s) {
    return CustomPaint(
      size: Size(c.size.width, c.size.height),
      painter: ImagePainter(image: m.image, x: c.x / s, y: c.y / s, scale: s),
    );
  }

  Widget _BuildPaintTextureRender(
      CanvasModel c, double s, Offset offset, Size size, bool isViewOriginal) {
    final ffiModel = c.parent.target!.ffiModel;
    final displays = ffiModel.pi.getCurDisplays();
    final children = <Widget>[];
    final rect = ffiModel.rect;
    if (rect == null) {
      return Container();
    }
    final curDisplay = ffiModel.pi.currentDisplay;
    for (var i = 0; i < displays.length; i++) {
      final textureId = widget
          .renderTextures[curDisplay == kAllDisplayValue ? i : curDisplay]
          ?.textureId;
      if (textureId != null) {
        children.add(Positioned(
          left: (displays[i].x - rect.left) * s + offset.dx,
          top: (displays[i].y - rect.top) * s + offset.dy,
          width: displays[i].width * s,
          height: displays[i].height * s,
          child: Obx(() => Texture(
                textureId: textureId.value,
                filterQuality:
                    isViewOriginal ? FilterQuality.none : FilterQuality.low,
              )),
        ));
      }
    }
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(children: children),
    );
  }

  MouseCursor _buildCursorOfCache(
      CursorModel cursor, double scale, CursorData? cache) {
    if (cache == null) {
      return MouseCursor.defer;
    } else {
      final key = cache.updateGetKey(scale);
      if (!cursor.cachedKeys.contains(key)) {
        debugPrint(
            "Register custom cursor with key $key (${cache.hotx},${cache.hoty})");
        // [Safety]
        // It's ok to call async registerCursor in current synchronous context,
        // because activating the cursor is also an async call and will always
        // be executed after this.
        custom_cursor_manager.CursorManager.instance
            .registerCursor(custom_cursor_manager.CursorData()
              ..buffer = cache.data!
              ..height = (cache.height * cache.scale).toInt()
              ..width = (cache.width * cache.scale).toInt()
              ..hotX = cache.hotx
              ..hotY = cache.hoty
              ..name = key);
        cursor.addKey(key);
      }
      return FlutterCustomMemoryImageCursor(key: key);
    }
  }

  MouseCursor _buildCustomCursor(BuildContext context, double scale) {
    final cursor = Provider.of<CursorModel>(context);
    final cache = cursor.cache ?? preDefaultCursor.cache;
    return _buildCursorOfCache(cursor, scale, cache);
  }

  MouseCursor _buildDisabledCursor(BuildContext context, double scale) {
    final cursor = Provider.of<CursorModel>(context);
    final cache = preForbiddenCursor.cache;
    return _buildCursorOfCache(cursor, scale, cache);
  }

  Widget _buildCrossScrollbarFromLayout(
    BuildContext context,
    Widget child,
    Size layoutSize,
    Size size,
    ScrollController horizontal,
    ScrollController vertical,
  ) {
    final scrollConfig = CustomMouseWheelScrollConfig(
        scrollDuration: kDefaultScrollDuration,
        scrollCurve: Curves.linearToEaseOut,
        mouseWheelTurnsThrottleTimeMs:
            kDefaultMouseWheelThrottleDuration.inMilliseconds,
        scrollAmountMultiplier: kDefaultScrollAmountMultiplier);
    var widget = child;
    if (layoutSize.width < size.width) {
      widget = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: horizontal,
          scrollDirection: Axis.horizontal,
          physics: cursorOverImage.isTrue
              ? const NeverScrollableScrollPhysics()
              : null,
          child: widget,
        ),
      );
    } else {
      widget = Row(
        children: [
          Container(
            width: ((layoutSize.width - size.width) ~/ 2).toDouble(),
          ),
          widget,
        ],
      );
    }
    if (layoutSize.height < size.height) {
      widget = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: vertical,
          physics: cursorOverImage.isTrue
              ? const NeverScrollableScrollPhysics()
              : null,
          child: widget,
        ),
      );
    } else {
      widget = Column(
        children: [
          Container(
            height: ((layoutSize.height - size.height) ~/ 2).toDouble(),
          ),
          widget,
        ],
      );
    }
    if (layoutSize.width < size.width) {
      widget = ImprovedScrolling(
        scrollController: horizontal,
        enableCustomMouseWheelScrolling: cursorOverImage.isFalse,
        customMouseWheelScrollConfig: scrollConfig,
        child: RawScrollbar(
          thickness: kScrollbarThickness,
          thumbColor: Colors.grey,
          controller: horizontal,
          thumbVisibility: false,
          trackVisibility: false,
          notificationPredicate: layoutSize.height < size.height
              ? (notification) => notification.depth == 1
              : defaultScrollNotificationPredicate,
          child: widget,
        ),
      );
    }
    if (layoutSize.height < size.height) {
      widget = ImprovedScrolling(
        scrollController: vertical,
        enableCustomMouseWheelScrolling: cursorOverImage.isFalse,
        customMouseWheelScrollConfig: scrollConfig,
        child: RawScrollbar(
          thickness: kScrollbarThickness,
          thumbColor: Colors.grey,
          controller: vertical,
          thumbVisibility: false,
          trackVisibility: false,
          child: widget,
        ),
      );
    }

    return Container(
      child: widget,
      width: layoutSize.width,
      height: layoutSize.height,
    );
  }

  Widget _buildListener(Widget child) {
    if (listenerBuilder != null) {
      return listenerBuilder!(child);
    } else {
      return child;
    }
  }
}

class CursorPaint extends StatelessWidget {
  final String id;
  final RxBool zoomCursor;

  const CursorPaint({
    Key? key,
    required this.id,
    required this.zoomCursor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    double hotx = m.hotx;
    double hoty = m.hoty;
    if (m.image == null) {
      if (preDefaultCursor.image != null) {
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }

    double cx = c.x;
    double cy = c.y;
    if (c.viewStyle.style == kRemoteViewStyleOriginal &&
        c.scrollStyle == ScrollStyle.scrollbar) {
      final rect = c.parent.target!.ffiModel.rect;
      if (rect == null) {
        // unreachable!
        debugPrint('unreachable! The displays rect is null.');
        return Container();
      }
      if (cx < 0) {
        final imageWidth = rect.width * c.scale;
        cx = -imageWidth * c.scrollX;
      }
      if (cy < 0) {
        final imageHeight = rect.height * c.scale;
        cy = -imageHeight * c.scrollY;
      }
    }

    double x = (m.x - hotx) * c.scale + cx;
    double y = (m.y - hoty) * c.scale + cy;
    double scale = 1.0;
    final isViewOriginal = c.viewStyle.style == kRemoteViewStyleOriginal;
    if (zoomCursor.value || isViewOriginal) {
      x = m.x - hotx + cx / c.scale;
      y = m.y - hoty + cy / c.scale;
      scale = c.scale;
    }

    return CustomPaint(
      painter: ImagePainter(
        image: m.image ?? preDefaultCursor.image,
        x: x,
        y: y,
        scale: scale,
      ),
    );
  }
}
