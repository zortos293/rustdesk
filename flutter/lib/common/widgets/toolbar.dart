import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/desktop_render_texture.dart';
import 'package:get/get.dart';

bool isEditOsPassword = false;

class TTextMenu {
  final Widget child;
  final VoidCallback onPressed;
  Widget? trailingIcon;
  bool divider;
  TTextMenu(
      {required this.child,
      required this.onPressed,
      this.trailingIcon,
      this.divider = false});
}

class TRadioMenu<T> {
  final Widget child;
  final T value;
  final T groupValue;
  final ValueChanged<T?>? onChanged;

  TRadioMenu(
      {required this.child,
      required this.value,
      required this.groupValue,
      required this.onChanged});
}

class TToggleMenu {
  final Widget child;
  final bool value;
  final ValueChanged<bool?>? onChanged;
  TToggleMenu(
      {required this.child, required this.value, required this.onChanged});
}

handleOsPasswordEditIcon(
    SessionID sessionId, OverlayDialogManager dialogManager) {
  isEditOsPassword = true;
  showSetOSPassword(
      sessionId, false, dialogManager, null, () => isEditOsPassword = false);
}

handleOsPasswordAction(
    SessionID sessionId, OverlayDialogManager dialogManager) async {
  if (isEditOsPassword) {
    isEditOsPassword = false;
    return;
  }
  final password =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-password') ??
          '';
  if (password.isEmpty) {
    showSetOSPassword(sessionId, true, dialogManager, password,
        () => isEditOsPassword = false);
  } else {
    bind.sessionInputOsPassword(sessionId: sessionId, value: password);
  }
}

List<TTextMenu> toolbarControls(BuildContext context, String id, FFI ffi) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final perms = ffiModel.permissions;
  final sessionId = ffi.sessionId;

  List<TTextMenu> v = [];
  // elevation
  if (perms['keyboard'] != false && ffi.elevationModel.showRequestMenu) {
    v.add(
      TTextMenu(
          child: Text(translate('Request Elevation')),
          onPressed: () =>
              showRequestElevationDialog(sessionId, ffi.dialogManager)),
    );
  }
  // osAccount / osPassword
  if (perms['keyboard'] != false) {
    v.add(
      TTextMenu(
        child: Row(children: [
          Text(translate(pi.isHeadless ? 'OS Account' : 'OS Password')),
        ]),
        trailingIcon: Transform.scale(
          scale: isDesktop ? 0.8 : 1,
          child: IconButton(
            onPressed: () {
              if (isMobile && Navigator.canPop(context)) {
                Navigator.pop(context);
              }
              if (pi.isHeadless) {
                showSetOSAccount(sessionId, ffi.dialogManager);
              } else {
                handleOsPasswordEditIcon(sessionId, ffi.dialogManager);
              }
            },
            icon: Icon(Icons.edit, color: isMobile ? MyTheme.accent : null),
          ),
        ),
        onPressed: () => pi.isHeadless
            ? showSetOSAccount(sessionId, ffi.dialogManager)
            : handleOsPasswordAction(sessionId, ffi.dialogManager),
      ),
    );
  }
  // paste
  if (isMobile && perms['keyboard'] != false && perms['clipboard'] != false) {
    v.add(TTextMenu(
        child: Text(translate('Paste')),
        onPressed: () async {
          ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
          if (data != null && data.text != null) {
            bind.sessionInputString(
                sessionId: sessionId, value: data.text ?? "");
          }
        }));
  }
  // reset canvas
  if (isMobile) {
    v.add(TTextMenu(
        child: Text(translate('Reset canvas')),
        onPressed: () => ffi.cursorModel.reset()));
  }
  // transferFile
  if (isDesktop) {
    v.add(
      TTextMenu(
          child: Text(translate('Transfer file')),
          onPressed: () => connect(context, id, isFileTransfer: true)),
    );
  }
  // tcpTunneling
  if (isDesktop) {
    v.add(
      TTextMenu(
          child: Text(translate('TCP tunneling')),
          onPressed: () => connect(context, id, isTcpTunneling: true)),
    );
  }
  // note
  if (bind
      .sessionGetAuditServerSync(sessionId: sessionId, typ: "conn")
      .isNotEmpty) {
    v.add(
      TTextMenu(
          child: Text(translate('Note')),
          onPressed: () => showAuditDialog(ffi)),
    );
  }
  // divider
  if (isDesktop) {
    v.add(TTextMenu(child: Offstage(), onPressed: () {}, divider: true));
  }
  // ctrlAltDel
  if (!ffiModel.viewOnly &&
      ffiModel.keyboard &&
      (pi.platform == kPeerPlatformLinux || pi.sasEnabled)) {
    v.add(
      TTextMenu(
          child: Text('${translate("Insert")} Ctrl + Alt + Del'),
          onPressed: () => bind.sessionCtrlAltDel(sessionId: sessionId)),
    );
  }
  // restart
  if (perms['restart'] != false &&
      (pi.platform == kPeerPlatformLinux ||
          pi.platform == kPeerPlatformWindows ||
          pi.platform == kPeerPlatformMacOS)) {
    v.add(
      TTextMenu(
          child: Text(translate('Restart remote device')),
          onPressed: () =>
              showRestartRemoteDevice(pi, id, sessionId, ffi.dialogManager)),
    );
  }
  // insertLock
  if (!ffiModel.viewOnly && ffi.ffiModel.keyboard) {
    v.add(
      TTextMenu(
          child: Text(translate('Insert Lock')),
          onPressed: () => bind.sessionLockScreen(sessionId: sessionId)),
    );
  }
  // blockUserInput
  if (ffi.ffiModel.keyboard &&
      ffi.ffiModel.permissions['block_input'] != false &&
      pi.platform == kPeerPlatformWindows) // privacy-mode != true ??
  {
    v.add(TTextMenu(
        child: Obx(() => Text(translate(
            '${BlockInputState.find(id).value ? 'Unb' : 'B'}lock user input'))),
        onPressed: () {
          RxBool blockInput = BlockInputState.find(id);
          bind.sessionToggleOption(
              sessionId: sessionId,
              value: '${blockInput.value ? 'un' : ''}block-input');
          blockInput.value = !blockInput.value;
        }));
  }
  // switchSides
  if (isDesktop &&
      ffiModel.keyboard &&
      pi.platform != kPeerPlatformAndroid &&
      pi.platform != kPeerPlatformMacOS &&
      versionCmp(pi.version, '1.2.0') >= 0 &&
      bind.peerGetDefaultSessionsCount(id: id) == 1) {
    v.add(TTextMenu(
        child: Text(translate('Switch Sides')),
        onPressed: () =>
            showConfirmSwitchSidesDialog(sessionId, id, ffi.dialogManager)));
  }
  // refresh
  if (pi.version.isNotEmpty) {
    v.add(TTextMenu(
      child: Text(translate('Refresh')),
      onPressed: () => sessionRefreshVideo(sessionId, pi),
    ));
  }
  // record
  if (!isDesktop &&
      (ffi.recordingModel.start || (perms["recording"] != false))) {
    v.add(TTextMenu(
        child: Row(
          children: [
            Text(translate(ffi.recordingModel.start
                ? 'Stop session recording'
                : 'Start session recording')),
            Padding(
              padding: EdgeInsets.only(left: 12),
              child: Icon(
                  ffi.recordingModel.start
                      ? Icons.pause_circle_filled
                      : Icons.videocam_outlined,
                  color: MyTheme.accent),
            )
          ],
        ),
        onPressed: () => ffi.recordingModel.toggle()));
  }
  // fingerprint
  if (!isDesktop) {
    v.add(TTextMenu(
      child: Text(translate('Copy Fingerprint')),
      onPressed: () => onCopyFingerprint(FingerprintState.find(id).value),
    ));
  }
  return v;
}

Future<List<TRadioMenu<String>>> toolbarViewStyle(
    BuildContext context, String id, FFI ffi) async {
  final groupValue =
      await bind.sessionGetViewStyle(sessionId: ffi.sessionId) ?? '';
  void onChanged(String? value) async {
    if (value == null) return;
    bind
        .sessionSetViewStyle(sessionId: ffi.sessionId, value: value)
        .then((_) => ffi.canvasModel.updateViewStyle());
  }

  return [
    TRadioMenu<String>(
        child: Text(translate('Scale original')),
        value: kRemoteViewStyleOriginal,
        groupValue: groupValue,
        onChanged: onChanged),
    TRadioMenu<String>(
        child: Text(translate('Scale adaptive')),
        value: kRemoteViewStyleAdaptive,
        groupValue: groupValue,
        onChanged: onChanged)
  ];
}

Future<List<TRadioMenu<String>>> toolbarImageQuality(
    BuildContext context, String id, FFI ffi) async {
  final groupValue =
      await bind.sessionGetImageQuality(sessionId: ffi.sessionId) ?? '';
  onChanged(String? value) async {
    if (value == null) return;
    await bind.sessionSetImageQuality(sessionId: ffi.sessionId, value: value);
  }

  return [
    TRadioMenu<String>(
        child: Text(translate('Good image quality')),
        value: kRemoteImageQualityBest,
        groupValue: groupValue,
        onChanged: onChanged),
    TRadioMenu<String>(
        child: Text(translate('Balanced')),
        value: kRemoteImageQualityBalanced,
        groupValue: groupValue,
        onChanged: onChanged),
    TRadioMenu<String>(
        child: Text(translate('Optimize reaction time')),
        value: kRemoteImageQualityLow,
        groupValue: groupValue,
        onChanged: onChanged),
    TRadioMenu<String>(
      child: Text(translate('Custom')),
      value: kRemoteImageQualityCustom,
      groupValue: groupValue,
      onChanged: (value) {
        onChanged(value);
        customImageQualityDialog(ffi.sessionId, id, ffi);
      },
    ),
  ];
}

Future<List<TRadioMenu<String>>> toolbarCodec(
    BuildContext context, String id, FFI ffi) async {
  final sessionId = ffi.sessionId;
  final alternativeCodecs =
      await bind.sessionAlternativeCodecs(sessionId: sessionId);
  final groupValue = await bind.sessionGetOption(
          sessionId: sessionId, arg: 'codec-preference') ??
      '';
  final List<bool> codecs = [];
  try {
    final Map codecsJson = jsonDecode(alternativeCodecs);
    final vp8 = codecsJson['vp8'] ?? false;
    final av1 = codecsJson['av1'] ?? false;
    final h264 = codecsJson['h264'] ?? false;
    final h265 = codecsJson['h265'] ?? false;
    codecs.add(vp8);
    codecs.add(av1);
    codecs.add(h264);
    codecs.add(h265);
  } catch (e) {
    debugPrint("Show Codec Preference err=$e");
  }
  final visible =
      codecs.length == 4 && (codecs[0] || codecs[1] || codecs[2] || codecs[3]);
  if (!visible) return [];
  onChanged(String? value) async {
    if (value == null) return;
    await bind.sessionPeerOption(
        sessionId: sessionId, name: 'codec-preference', value: value);
    bind.sessionChangePreferCodec(sessionId: sessionId);
  }

  TRadioMenu<String> radio(String label, String value, bool enabled) {
    return TRadioMenu<String>(
        child: Text(translate(label)),
        value: value,
        groupValue: groupValue,
        onChanged: enabled ? onChanged : null);
  }

  return [
    radio('Auto', 'auto', true),
    if (codecs[0]) radio('VP8', 'vp8', codecs[0]),
    radio('VP9', 'vp9', true),
    if (codecs[1]) radio('AV1', 'av1', codecs[1]),
    if (codecs[2]) radio('H264', 'h264', codecs[2]),
    if (codecs[3]) radio('H265', 'h265', codecs[3]),
  ];
}

Future<List<TToggleMenu>> toolbarDisplayToggle(
    BuildContext context, String id, FFI ffi) async {
  List<TToggleMenu> v = [];
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final perms = ffiModel.permissions;
  final sessionId = ffi.sessionId;

  // show remote cursor
  if (pi.platform != kPeerPlatformAndroid &&
      !ffi.canvasModel.cursorEmbedded &&
      !pi.isWayland) {
    final state = ShowRemoteCursorState.find(id);
    final enabled = !ffiModel.viewOnly;
    final option = 'show-remote-cursor';
    v.add(TToggleMenu(
        child: Text(translate('Show remote cursor')),
        value: state.value,
        onChanged: enabled
            ? (value) async {
                if (value == null) return;
                await bind.sessionToggleOption(
                    sessionId: sessionId, value: option);
                state.value = bind.sessionGetToggleOptionSync(
                    sessionId: sessionId, arg: option);
              }
            : null));
  }
  // zoom cursor
  final viewStyle = await bind.sessionGetViewStyle(sessionId: sessionId) ?? '';
  if (!isMobile &&
      pi.platform != kPeerPlatformAndroid &&
      viewStyle != kRemoteViewStyleOriginal) {
    final option = 'zoom-cursor';
    final peerState = PeerBoolOption.find(id, option);
    v.add(TToggleMenu(
      child: Text(translate('Zoom cursor')),
      value: peerState.value,
      onChanged: (value) async {
        if (value == null) return;
        await bind.sessionToggleOption(sessionId: sessionId, value: option);
        peerState.value =
            bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
      },
    ));
  }
  // show quality monitor
  final option = 'show-quality-monitor';
  v.add(TToggleMenu(
      value: bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option),
      onChanged: (value) async {
        if (value == null) return;
        await bind.sessionToggleOption(sessionId: sessionId, value: option);
        ffi.qualityMonitorModel.checkShowQualityMonitor(sessionId);
      },
      child: Text(translate('Show quality monitor'))));
  // mute
  if (perms['audio'] != false) {
    final option = 'disable-audio';
    final value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) {
          if (value == null) return;
          bind.sessionToggleOption(sessionId: sessionId, value: option);
        },
        child: Text(translate('Mute'))));
  }
  // file copy and paste
  if (perms['file'] != false &&
      bind.mainHasFileClipboard() &&
      pi.platformAdditions.containsKey(kPlatformAdditionsHasFileClipboard)) {
    final option = 'enable-file-transfer';
    final value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) {
          if (value == null) return;
          bind.sessionToggleOption(sessionId: sessionId, value: option);
        },
        child: Text(translate('Enable file copy and paste'))));
  }
  // disable clipboard
  if (ffiModel.keyboard && perms['clipboard'] != false) {
    final enabled = !ffiModel.viewOnly;
    final option = 'disable-clipboard';
    var value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    if (ffiModel.viewOnly) value = true;
    v.add(TToggleMenu(
        value: value,
        onChanged: enabled
            ? (value) {
                if (value == null) return;
                bind.sessionToggleOption(sessionId: sessionId, value: option);
              }
            : null,
        child: Text(translate('Disable clipboard'))));
  }
  // lock after session end
  if (ffiModel.keyboard) {
    final option = 'lock-after-session-end';
    final value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) {
          if (value == null) return;
          bind.sessionToggleOption(sessionId: sessionId, value: option);
        },
        child: Text(translate('Lock after session end'))));
  }
  // swap key
  if (ffiModel.keyboard &&
      ((Platform.isMacOS && pi.platform != kPeerPlatformMacOS) ||
          (!Platform.isMacOS && pi.platform == kPeerPlatformMacOS))) {
    final option = 'allow_swap_key';
    final value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) {
          if (value == null) return;
          bind.sessionToggleOption(sessionId: sessionId, value: option);
        },
        child: Text(translate('Swap control-command key'))));
  }

  if (useTextureRender &&
      pi.isSupportMultiDisplay &&
      PrivacyModeState.find(id).isEmpty &&
      pi.displaysCount.value > 1 &&
      bind.mainGetUserDefaultOption(key: kKeyShowMonitorsToolbar) == 'Y') {
    final value =
        bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) ==
            'Y';
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) {
          if (value == null) return;
          bind.sessionSetDisplaysAsIndividualWindows(
              sessionId: sessionId, value: value ? 'Y' : '');
        },
        child: Text(translate('Show displays as individual windows'))));
  }

  final screenList = await getScreenRectList();
  if (useTextureRender && pi.isSupportMultiDisplay && screenList.length > 1) {
    final value = bind.sessionGetUseAllMyDisplaysForTheRemoteSession(
            sessionId: ffi.sessionId) ==
        'Y';
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) {
          if (value == null) return;
          bind.sessionSetUseAllMyDisplaysForTheRemoteSession(
              sessionId: sessionId, value: value ? 'Y' : '');
        },
        child: Text(translate('Use all my displays for the remote session'))));
  }

  // 444
  final codec_format = ffi.qualityMonitorModel.data.codecFormat;
  if (versionCmp(pi.version, "1.2.4") >= 0 &&
      (codec_format == "AV1" || codec_format == "VP9")) {
    final option = 'i444';
    final value =
        bind.sessionGetToggleOptionSync(sessionId: sessionId, arg: option);
    v.add(TToggleMenu(
        value: value,
        onChanged: (value) async {
          if (value == null) return;
          await bind.sessionToggleOption(sessionId: sessionId, value: option);
          bind.sessionChangePreferCodec(sessionId: sessionId);
        },
        child: Text(translate('True color (4:4:4)'))));
  }

  return v;
}

var togglePrivacyModeTime = DateTime.now().subtract(const Duration(hours: 1));

List<TToggleMenu> toolbarPrivacyMode(
    RxString privacyModeState, BuildContext context, String id, FFI ffi) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final sessionId = ffi.sessionId;

  getDefaultMenu(Future<void> Function(SessionID sid, String opt) toggleFunc) {
    return TToggleMenu(
        value: privacyModeState.isNotEmpty,
        onChanged: (value) {
          if (value == null) return;
          if (ffiModel.pi.currentDisplay != 0 &&
              ffiModel.pi.currentDisplay != kAllDisplayValue) {
            msgBox(sessionId, 'custom-nook-nocancel-hasclose', 'info',
                'Please switch to Display 1 first', '', ffi.dialogManager);
            return;
          }
          final option = 'privacy-mode';
          toggleFunc(sessionId, option);
        },
        child: Text(translate('Privacy mode')));
  }

  final privacyModeImpls =
      pi.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl]
          as List<dynamic>?;
  if (privacyModeImpls == null) {
    return [
      getDefaultMenu((sid, opt) async {
        bind.sessionToggleOption(sessionId: sid, value: opt);
        togglePrivacyModeTime = DateTime.now();
      })
    ];
  }
  if (privacyModeImpls.isEmpty) {
    return [];
  }

  if (privacyModeImpls.length == 1) {
    final implKey = (privacyModeImpls[0] as List<dynamic>)[0] as String;
    return [
      getDefaultMenu((sid, opt) async {
        bind.sessionTogglePrivacyMode(
            sessionId: sid, implKey: implKey, on: privacyModeState.isEmpty);
        togglePrivacyModeTime = DateTime.now();
      })
    ];
  } else {
    return privacyModeImpls.map((e) {
      final implKey = (e as List<dynamic>)[0] as String;
      final implName = (e)[1] as String;
      return TToggleMenu(
          child: Text(translate(implName)),
          value: privacyModeState.value == implKey,
          onChanged: (value) {
            if (value == null) return;
            togglePrivacyModeTime = DateTime.now();
            bind.sessionTogglePrivacyMode(
                sessionId: sessionId, implKey: implKey, on: value);
          });
    }).toList();
  }
}
