use crate::{
    client::*,
    flutter_ffi::{EventToUI, SessionID},
    ui_session_interface::{io_loop, InvokeUiSession, Session},
};
use flutter_rust_bridge::StreamSink;
use hbb_common::{
    anyhow::anyhow, bail, config::LocalConfig, get_version_number, log, message_proto::*,
    rendezvous_proto::ConnType, ResultType,
};
#[cfg(feature = "flutter_texture_render")]
use hbb_common::{
    dlopen::{
        symbor::{Library, Symbol},
        Error as LibError,
    },
    libc::c_void,
};
use serde_json::json;

use std::{
    collections::HashMap,
    ffi::CString,
    os::raw::{c_char, c_int},
    str::FromStr,
    sync::{Arc, RwLock},
};

/// tag "main" for [Desktop Main Page] and [Mobile (Client and Server)] (the mobile don't need multiple windows, only one global event stream is needed)
/// tag "cm" only for [Desktop CM Page]
pub(crate) const APP_TYPE_MAIN: &str = "main";
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) const APP_TYPE_CM: &str = "cm";
#[cfg(any(target_os = "android", target_os = "ios"))]
pub(crate) const APP_TYPE_CM: &str = "main";

// Do not remove the following constants.
// Uncomment them when they are used.
// pub(crate) const APP_TYPE_DESKTOP_REMOTE: &str = "remote";
// pub(crate) const APP_TYPE_DESKTOP_FILE_TRANSFER: &str = "file transfer";
// pub(crate) const APP_TYPE_DESKTOP_PORT_FORWARD: &str = "port forward";

pub type FlutterSession = Arc<Session<FlutterHandler>>;

lazy_static::lazy_static! {
    pub(crate) static ref CUR_SESSION_ID: RwLock<SessionID> = Default::default();
    static ref GLOBAL_EVENT_STREAM: RwLock<HashMap<String, StreamSink<String>>> = Default::default(); // rust to dart event channel
}

#[cfg(all(target_os = "windows", feature = "flutter_texture_render"))]
lazy_static::lazy_static! {
    pub static ref TEXTURE_RGBA_RENDERER_PLUGIN: Result<Library, LibError> = Library::open("texture_rgba_renderer_plugin.dll");
}

#[cfg(all(target_os = "linux", feature = "flutter_texture_render"))]
lazy_static::lazy_static! {
    pub static ref TEXTURE_RGBA_RENDERER_PLUGIN: Result<Library, LibError> = Library::open("libtexture_rgba_renderer_plugin.so");
}

#[cfg(all(target_os = "macos", feature = "flutter_texture_render"))]
lazy_static::lazy_static! {
    pub static ref TEXTURE_RGBA_RENDERER_PLUGIN: Result<Library, LibError> = Library::open_self();
}

/// FFI for rustdesk core's main entry.
/// Return true if the app should continue running with UI(possibly Flutter), false if the app should exit.
#[cfg(not(windows))]
#[no_mangle]
pub extern "C" fn rustdesk_core_main() -> bool {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if crate::core_main::core_main().is_some() {
        return true;
    } else {
        #[cfg(target_os = "macos")]
        std::process::exit(0);
    }
    false
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub extern "C" fn handle_applicationShouldOpenUntitledFile() {
    crate::platform::macos::handle_application_should_open_untitled_file();
}

#[cfg(windows)]
#[no_mangle]
pub extern "C" fn rustdesk_core_main_args(args_len: *mut c_int) -> *mut *mut c_char {
    unsafe { std::ptr::write(args_len, 0) };
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        if let Some(args) = crate::core_main::core_main() {
            return rust_args_to_c_args(args, args_len);
        }
        return std::ptr::null_mut() as _;
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return std::ptr::null_mut() as _;
}

// https://gist.github.com/iskakaushik/1c5b8aa75c77479c33c4320913eebef6
#[cfg(windows)]
fn rust_args_to_c_args(args: Vec<String>, outlen: *mut c_int) -> *mut *mut c_char {
    let mut v = vec![];

    // Let's fill a vector with null-terminated strings
    for s in args {
        match CString::new(s) {
            Ok(s) => v.push(s),
            Err(_) => return std::ptr::null_mut() as _,
        }
    }

    // Turning each null-terminated string into a pointer.
    // `into_raw` takes ownershop, gives us the pointer and does NOT drop the data.
    let mut out = v.into_iter().map(|s| s.into_raw()).collect::<Vec<_>>();

    // Make sure we're not wasting space.
    out.shrink_to_fit();
    debug_assert!(out.len() == out.capacity());

    // Get the pointer to our vector.
    let len = out.len();
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);

    // Let's write back the length the caller can expect
    unsafe { std::ptr::write(outlen, len as c_int) };

    // Finally return the data
    ptr
}

#[no_mangle]
pub unsafe extern "C" fn free_c_args(ptr: *mut *mut c_char, len: c_int) {
    let len = len as usize;

    // Get back our vector.
    // Previously we shrank to fit, so capacity == length.
    let v = Vec::from_raw_parts(ptr, len, len);

    // Now drop one string at a time.
    for elem in v {
        let s = CString::from_raw(elem);
        std::mem::drop(s);
    }

    // Afterwards the vector will be dropped and thus freed.
}

#[derive(Default)]
struct SessionHandler {
    event_stream: Option<StreamSink<EventToUI>>,
    #[cfg(feature = "flutter_texture_render")]
    notify_rendered: bool,
    #[cfg(feature = "flutter_texture_render")]
    renderer: VideoRenderer,
}

#[cfg(feature = "flutter_texture_render")]
#[derive(Default, Clone)]
pub struct FlutterHandler {
    // ui session id -> display handler data
    session_handlers: Arc<RwLock<HashMap<SessionID, SessionHandler>>>,
    peer_info: Arc<RwLock<PeerInfo>>,
    #[cfg(feature = "plugin_framework")]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    hooks: Arc<RwLock<HashMap<String, SessionHook>>>,
}

#[cfg(not(feature = "flutter_texture_render"))]
#[derive(Default, Clone)]
struct RgbaData {
    // SAFETY: [rgba] is guarded by [rgba_valid], and it's safe to reach [rgba] with `rgba_valid == true`.
    // We must check the `rgba_valid` before reading [rgba].
    data: Vec<u8>,
    valid: bool,
}

#[cfg(not(feature = "flutter_texture_render"))]
#[derive(Default, Clone)]
pub struct FlutterHandler {
    session_handlers: Arc<RwLock<HashMap<SessionID, SessionHandler>>>,
    display_rgbas: Arc<RwLock<HashMap<usize, RgbaData>>>,
    peer_info: Arc<RwLock<PeerInfo>>,
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    hooks: Arc<RwLock<HashMap<String, SessionHook>>>,
}

#[cfg(feature = "flutter_texture_render")]
pub type FlutterRgbaRendererPluginOnRgba = unsafe extern "C" fn(
    texture_rgba: *mut c_void,
    buffer: *const u8,
    len: c_int,
    width: c_int,
    height: c_int,
    dst_rgba_stride: c_int,
);

#[cfg(feature = "flutter_texture_render")]
pub(super) type TextureRgbaPtr = usize;

#[cfg(feature = "flutter_texture_render")]
struct DisplaySessionInfo {
    // TextureRgba pointer in flutter native.
    texture_rgba_ptr: TextureRgbaPtr,
    size: (usize, usize),
}

// Video Texture Renderer in Flutter
#[cfg(feature = "flutter_texture_render")]
#[derive(Clone)]
struct VideoRenderer {
    is_support_multi_ui_session: bool,
    map_display_sessions: Arc<RwLock<HashMap<usize, DisplaySessionInfo>>>,
    on_rgba_func: Option<Symbol<'static, FlutterRgbaRendererPluginOnRgba>>,
}

#[cfg(feature = "flutter_texture_render")]
impl Default for VideoRenderer {
    fn default() -> Self {
        let on_rgba_func = match &*TEXTURE_RGBA_RENDERER_PLUGIN {
            Ok(lib) => {
                let find_sym_res = unsafe {
                    lib.symbol::<FlutterRgbaRendererPluginOnRgba>("FlutterRgbaRendererPluginOnRgba")
                };
                match find_sym_res {
                    Ok(sym) => Some(sym),
                    Err(e) => {
                        log::error!("Failed to find symbol FlutterRgbaRendererPluginOnRgba, {e}");
                        None
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to load texture rgba renderer plugin, {e}");
                None
            }
        };
        Self {
            map_display_sessions: Default::default(),
            is_support_multi_ui_session: false,
            on_rgba_func,
        }
    }
}

#[cfg(feature = "flutter_texture_render")]
impl VideoRenderer {
    #[inline]
    fn set_size(&mut self, display: usize, width: usize, height: usize) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        if let Some(info) = sessions_lock.get_mut(&display) {
            info.size = (width, height);
        } else {
            sessions_lock.insert(
                display,
                DisplaySessionInfo {
                    texture_rgba_ptr: usize::default(),
                    size: (width, height),
                },
            );
        }
    }

    fn register_texture(&self, display: usize, ptr: usize) {
        let mut sessions_lock = self.map_display_sessions.write().unwrap();
        if ptr == 0 {
            sessions_lock.remove(&display);
        } else {
            if let Some(info) = sessions_lock.get_mut(&display) {
                if info.texture_rgba_ptr != 0 && info.texture_rgba_ptr != ptr as TextureRgbaPtr {
                    log::error!("unreachable, texture_rgba_ptr is not null and not equal to ptr");
                }
                info.texture_rgba_ptr = ptr as _;
            } else {
                if ptr != 0 {
                    sessions_lock.insert(
                        display,
                        DisplaySessionInfo {
                            texture_rgba_ptr: ptr as _,
                            size: (0, 0),
                        },
                    );
                }
            }
        }
    }

    pub fn on_rgba(&self, display: usize, rgba: &scrap::ImageRgb) {
        let read_lock = self.map_display_sessions.read().unwrap();
        let opt_info = if !self.is_support_multi_ui_session {
            read_lock.values().next()
        } else {
            read_lock.get(&display)
        };
        let Some(info) = opt_info else {
            return;
        };
        if info.texture_rgba_ptr == usize::default() {
            return;
        }

        // It is also Ok to skip this check.
        if info.size.0 != rgba.w || info.size.1 != rgba.h {
            log::error!(
                "width/height mismatch: ({},{}) != ({},{})",
                info.size.0,
                info.size.1,
                rgba.w,
                rgba.h
            );
            return;
        }
        if let Some(func) = &self.on_rgba_func {
            unsafe {
                func(
                    info.texture_rgba_ptr as _,
                    rgba.raw.as_ptr() as _,
                    rgba.raw.len() as _,
                    rgba.w as _,
                    rgba.h as _,
                    rgba.stride() as _,
                )
            };
        }
    }
}

impl SessionHandler {
    pub fn on_waiting_for_image_dialog_show(&mut self) {
        #[cfg(any(feature = "flutter_texture_render"))]
        {
            self.notify_rendered = false;
        }
        // rgba array render will notify every frame
    }
}

impl FlutterHandler {
    /// Push an event to all the event queues.
    /// An event is stored as json in the event queues.
    ///
    /// # Arguments
    ///
    /// * `name` - The name of the event.
    /// * `event` - Fields of the event content.
    pub fn push_event(&self, name: &str, event: Vec<(&str, &str)>) {
        let mut h: HashMap<&str, &str> = event.iter().cloned().collect();
        debug_assert!(h.get("name").is_none());
        h.insert("name", name);
        let out = serde_json::ser::to_string(&h).unwrap_or("".to_owned());
        for (_, session) in self.session_handlers.read().unwrap().iter() {
            if let Some(stream) = &session.event_stream {
                stream.add(EventToUI::Event(out.clone()));
            }
        }
    }

    pub(crate) fn close_event_stream(&self, session_id: SessionID) {
        // to-do: Make sure the following logic is correct.
        // No need to remove the display handler, because it will be removed when the connection is closed.
        if let Some(session) = self.session_handlers.write().unwrap().get_mut(&session_id) {
            try_send_close_event(&session.event_stream);
        }
    }

    fn make_displays_msg(displays: &Vec<DisplayInfo>) -> String {
        let mut msg_vec = Vec::new();
        for ref d in displays.iter() {
            let mut h: HashMap<&str, i32> = Default::default();
            h.insert("x", d.x);
            h.insert("y", d.y);
            h.insert("width", d.width);
            h.insert("height", d.height);
            h.insert("cursor_embedded", if d.cursor_embedded { 1 } else { 0 });
            if let Some(original_resolution) = d.original_resolution.as_ref() {
                h.insert("original_width", original_resolution.width);
                h.insert("original_height", original_resolution.height);
            }
            msg_vec.push(h);
        }
        serde_json::ser::to_string(&msg_vec).unwrap_or("".to_owned())
    }

    #[cfg(feature = "plugin_framework")]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub(crate) fn add_session_hook(&self, key: String, hook: SessionHook) -> bool {
        let mut hooks = self.hooks.write().unwrap();
        if hooks.contains_key(&key) {
            // Already has the hook with this key.
            return false;
        }
        let _ = hooks.insert(key, hook);
        true
    }

    #[cfg(feature = "plugin_framework")]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub(crate) fn remove_session_hook(&self, key: &String) -> bool {
        let mut hooks = self.hooks.write().unwrap();
        if !hooks.contains_key(key) {
            // The hook with this key does not found.
            return false;
        }
        let _ = hooks.remove(key);
        true
    }
}

impl InvokeUiSession for FlutterHandler {
    fn set_cursor_data(&self, cd: CursorData) {
        let colors = hbb_common::compress::decompress(&cd.colors);
        self.push_event(
            "cursor_data",
            vec![
                ("id", &cd.id.to_string()),
                ("hotx", &cd.hotx.to_string()),
                ("hoty", &cd.hoty.to_string()),
                ("width", &cd.width.to_string()),
                ("height", &cd.height.to_string()),
                (
                    "colors",
                    &serde_json::ser::to_string(&colors).unwrap_or("".to_owned()),
                ),
            ],
        );
    }

    fn set_cursor_id(&self, id: String) {
        self.push_event("cursor_id", vec![("id", &id.to_string())]);
    }

    fn set_cursor_position(&self, cp: CursorPosition) {
        self.push_event(
            "cursor_position",
            vec![("x", &cp.x.to_string()), ("y", &cp.y.to_string())],
        );
    }

    /// unused in flutter, use switch_display or set_peer_info
    fn set_display(&self, _x: i32, _y: i32, _w: i32, _h: i32, _cursor_embedded: bool) {}

    fn update_privacy_mode(&self) {
        self.push_event("update_privacy_mode", [].into());
    }

    fn set_permission(&self, name: &str, value: bool) {
        self.push_event("permission", vec![(name, &value.to_string())]);
    }

    // unused in flutter
    fn close_success(&self) {}

    fn update_quality_status(&self, status: QualityStatus) {
        const NULL: String = String::new();
        self.push_event(
            "update_quality_status",
            vec![
                ("speed", &status.speed.map_or(NULL, |it| it)),
                (
                    "fps",
                    &serde_json::ser::to_string(&status.fps).unwrap_or(NULL.to_owned()),
                ),
                ("delay", &status.delay.map_or(NULL, |it| it.to_string())),
                (
                    "target_bitrate",
                    &status.target_bitrate.map_or(NULL, |it| it.to_string()),
                ),
                (
                    "codec_format",
                    &status.codec_format.map_or(NULL, |it| it.to_string()),
                ),
                ("chroma", &status.chroma.map_or(NULL, |it| it.to_string())),
            ],
        );
    }

    fn set_connection_type(&self, is_secured: bool, direct: bool) {
        self.push_event(
            "connection_ready",
            vec![
                ("secure", &is_secured.to_string()),
                ("direct", &direct.to_string()),
            ],
        );
    }

    fn set_fingerprint(&self, fingerprint: String) {
        self.push_event("fingerprint", vec![("fingerprint", &fingerprint)]);
    }

    fn job_error(&self, id: i32, err: String, file_num: i32) {
        self.push_event(
            "job_error",
            vec![
                ("id", &id.to_string()),
                ("err", &err),
                ("file_num", &file_num.to_string()),
            ],
        );
    }

    fn job_done(&self, id: i32, file_num: i32) {
        self.push_event(
            "job_done",
            vec![("id", &id.to_string()), ("file_num", &file_num.to_string())],
        );
    }

    // unused in flutter
    fn clear_all_jobs(&self) {}

    fn load_last_job(&self, _cnt: i32, job_json: &str) {
        self.push_event("load_last_job", vec![("value", job_json)]);
    }

    fn update_folder_files(
        &self,
        id: i32,
        entries: &Vec<FileEntry>,
        path: String,
        #[allow(unused_variables)] is_local: bool,
        only_count: bool,
    ) {
        // TODO opt
        if only_count {
            self.push_event(
                "update_folder_files",
                vec![("info", &make_fd_flutter(id, entries, only_count))],
            );
        } else {
            self.push_event(
                "file_dir",
                vec![
                    ("value", &crate::common::make_fd_to_json(id, path, entries)),
                    ("is_local", "false"),
                ],
            );
        }
    }

    // unused in flutter
    fn update_transfer_list(&self) {}

    // unused in flutter // TEST flutter
    fn confirm_delete_files(&self, _id: i32, _i: i32, _name: String) {}

    fn override_file_confirm(
        &self,
        id: i32,
        file_num: i32,
        to: String,
        is_upload: bool,
        is_identical: bool,
    ) {
        self.push_event(
            "override_file_confirm",
            vec![
                ("id", &id.to_string()),
                ("file_num", &file_num.to_string()),
                ("read_path", &to),
                ("is_upload", &is_upload.to_string()),
                ("is_identical", &is_identical.to_string()),
            ],
        );
    }

    fn job_progress(&self, id: i32, file_num: i32, speed: f64, finished_size: f64) {
        self.push_event(
            "job_progress",
            vec![
                ("id", &id.to_string()),
                ("file_num", &file_num.to_string()),
                ("speed", &speed.to_string()),
                ("finished_size", &finished_size.to_string()),
            ],
        );
    }

    // unused in flutter
    fn adapt_size(&self) {}

    #[inline]
    #[cfg(not(feature = "flutter_texture_render"))]
    fn on_rgba(&self, display: usize, rgba: &mut scrap::ImageRgb) {
        // Give a chance for plugins or etc to hook a rgba data.
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        for (key, hook) in self.hooks.read().unwrap().iter() {
            match hook {
                SessionHook::OnSessionRgba(cb) => {
                    cb(key.to_owned(), rgba);
                }
            }
        }
        // If the current rgba is not fetched by flutter, i.e., is valid.
        // We give up sending a new event to flutter.
        let mut rgba_write_lock = self.display_rgbas.write().unwrap();
        if let Some(rgba_data) = rgba_write_lock.get_mut(&display) {
            if rgba_data.valid {
                return;
            } else {
                rgba_data.valid = true;
            }
            // Return the rgba buffer to the video handler for reusing allocated rgba buffer.
            std::mem::swap::<Vec<u8>>(&mut rgba.raw, &mut rgba_data.data);
        } else {
            let mut rgba_data = RgbaData::default();
            std::mem::swap::<Vec<u8>>(&mut rgba.raw, &mut rgba_data.data);
            rgba_write_lock.insert(display, rgba_data);
        }
        drop(rgba_write_lock);

        // Non-texture-render UI does not support multiple displays in the one UI session.
        // It's Ok to notify each session for now.
        for h in self.session_handlers.read().unwrap().values() {
            if let Some(stream) = &h.event_stream {
                stream.add(EventToUI::Rgba(display));
            }
        }
    }

    #[inline]
    #[cfg(feature = "flutter_texture_render")]
    fn on_rgba(&self, display: usize, rgba: &mut scrap::ImageRgb) {
        let mut try_notify_sessions = Vec::new();
        for (id, session) in self.session_handlers.read().unwrap().iter() {
            session.renderer.on_rgba(display, rgba);
            if !session.notify_rendered {
                try_notify_sessions.push(id.clone());
            }
        }
        if try_notify_sessions.len() > 0 {
            let mut write_lock = self.session_handlers.write().unwrap();
            for id in try_notify_sessions.iter() {
                if let Some(session) = write_lock.get_mut(id) {
                    if let Some(stream) = &session.event_stream {
                        stream.add(EventToUI::Rgba(display));
                        session.notify_rendered = true;
                    }
                }
            }
        }
    }

    fn set_peer_info(&self, pi: &PeerInfo) {
        let displays = Self::make_displays_msg(&pi.displays);
        let mut features: HashMap<&str, i32> = Default::default();
        for ref f in pi.features.iter() {
            features.insert("privacy_mode", if f.privacy_mode { 1 } else { 0 });
        }
        // compatible with 1.1.9
        if get_version_number(&pi.version) < get_version_number("1.2.0") {
            features.insert("privacy_mode", 0);
        }
        let features = serde_json::ser::to_string(&features).unwrap_or("".to_owned());
        let resolutions = serialize_resolutions(&pi.resolutions.resolutions);
        *self.peer_info.write().unwrap() = pi.clone();
        #[cfg(feature = "flutter_texture_render")]
        {
            self.session_handlers
                .write()
                .unwrap()
                .values_mut()
                .for_each(|h| {
                    h.renderer.is_support_multi_ui_session =
                        crate::common::is_support_multi_ui_session(&pi.version);
                });
        }
        self.push_event(
            "peer_info",
            vec![
                ("username", &pi.username),
                ("hostname", &pi.hostname),
                ("platform", &pi.platform),
                ("sas_enabled", &pi.sas_enabled.to_string()),
                ("displays", &displays),
                ("version", &pi.version),
                ("features", &features),
                ("current_display", &pi.current_display.to_string()),
                ("resolutions", &resolutions),
                ("platform_additions", &pi.platform_additions),
            ],
        );
    }

    fn set_displays(&self, displays: &Vec<DisplayInfo>) {
        self.peer_info.write().unwrap().displays = displays.clone();
        self.push_event(
            "sync_peer_info",
            vec![("displays", &Self::make_displays_msg(displays))],
        );
    }

    fn set_platform_additions(&self, data: &str) {
        self.push_event(
            "sync_platform_additions",
            vec![("platform_additions", &data)],
        )
    }

    fn on_connected(&self, _conn_type: ConnType) {}

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, link: &str, retry: bool) {
        let has_retry = if retry { "true" } else { "" };
        self.push_event(
            "msgbox",
            vec![
                ("type", msgtype),
                ("title", title),
                ("text", text),
                ("link", link),
                ("hasRetry", has_retry),
            ],
        );
    }

    fn cancel_msgbox(&self, tag: &str) {
        self.push_event("cancel_msgbox", vec![("tag", tag)]);
    }

    fn new_message(&self, msg: String) {
        self.push_event("chat_client_mode", vec![("text", &msg)]);
    }

    fn switch_display(&self, display: &SwitchDisplay) {
        let resolutions = serialize_resolutions(&display.resolutions.resolutions);
        self.push_event(
            "switch_display",
            vec![
                ("display", &display.display.to_string()),
                ("x", &display.x.to_string()),
                ("y", &display.y.to_string()),
                ("width", &display.width.to_string()),
                ("height", &display.height.to_string()),
                (
                    "cursor_embedded",
                    &{
                        if display.cursor_embedded {
                            1
                        } else {
                            0
                        }
                    }
                    .to_string(),
                ),
                ("resolutions", &resolutions),
                (
                    "original_width",
                    &display.original_resolution.width.to_string(),
                ),
                (
                    "original_height",
                    &display.original_resolution.height.to_string(),
                ),
            ],
        );
    }

    fn update_block_input_state(&self, on: bool) {
        self.push_event(
            "update_block_input_state",
            [("input_state", if on { "on" } else { "off" })].into(),
        );
    }

    #[cfg(any(target_os = "android", target_os = "ios"))]
    fn clipboard(&self, content: String) {
        self.push_event("clipboard", vec![("content", &content)]);
    }

    fn switch_back(&self, peer_id: &str) {
        self.push_event("switch_back", [("peer_id", peer_id)].into());
    }

    fn portable_service_running(&self, running: bool) {
        self.push_event(
            "portable_service_running",
            [("running", running.to_string().as_str())].into(),
        );
    }

    fn on_voice_call_started(&self) {
        self.push_event("on_voice_call_started", [].into());
    }

    fn on_voice_call_closed(&self, reason: &str) {
        let _res = self.push_event("on_voice_call_closed", [("reason", reason)].into());
    }

    fn on_voice_call_waiting(&self) {
        self.push_event("on_voice_call_waiting", [].into());
    }

    fn on_voice_call_incoming(&self) {
        self.push_event("on_voice_call_incoming", [].into());
    }

    #[inline]
    fn get_rgba(&self, _display: usize) -> *const u8 {
        #[cfg(not(feature = "flutter_texture_render"))]
        if let Some(rgba_data) = self.display_rgbas.read().unwrap().get(&_display) {
            if rgba_data.valid {
                return rgba_data.data.as_ptr();
            }
        }
        std::ptr::null_mut()
    }

    #[inline]
    fn next_rgba(&self, _display: usize) {
        #[cfg(not(feature = "flutter_texture_render"))]
        if let Some(rgba_data) = self.display_rgbas.write().unwrap().get_mut(&_display) {
            rgba_data.valid = false;
        }
    }
}

// This function is only used for the default connection session.
pub fn session_add_existed(peer_id: String, session_id: SessionID) -> ResultType<()> {
    sessions::insert_peer_session_id(peer_id, ConnType::DEFAULT_CONN, session_id);
    Ok(())
}

/// Create a new remote session with the given id.
///
/// # Arguments
///
/// * `id` - The identifier of the remote session with prefix. Regex: [\w]*[\_]*[\d]+
/// * `is_file_transfer` - If the session is used for file transfer.
/// * `is_port_forward` - If the session is used for port forward.
pub fn session_add(
    session_id: &SessionID,
    id: &str,
    is_file_transfer: bool,
    is_port_forward: bool,
    is_rdp: bool,
    switch_uuid: &str,
    force_relay: bool,
    password: String,
) -> ResultType<FlutterSession> {
    let conn_type = if is_file_transfer {
        ConnType::FILE_TRANSFER
    } else if is_port_forward {
        if is_rdp {
            ConnType::RDP
        } else {
            ConnType::PORT_FORWARD
        }
    } else {
        ConnType::DEFAULT_CONN
    };

    // to-do: check the same id session.
    if let Some(session) = sessions::get_session_by_session_id(&session_id) {
        if session.lc.read().unwrap().conn_type != conn_type {
            bail!("same session id is found with different conn type?");
        }
        // The same session is added before?
        bail!("same session id is found");
    }

    LocalConfig::set_remote_id(&id);

    let session: Session<FlutterHandler> = Session {
        password,
        server_keyboard_enabled: Arc::new(RwLock::new(true)),
        server_file_transfer_enabled: Arc::new(RwLock::new(true)),
        server_clipboard_enabled: Arc::new(RwLock::new(true)),
        ..Default::default()
    };

    let switch_uuid = if switch_uuid.is_empty() {
        None
    } else {
        Some(switch_uuid.to_string())
    };

    session
        .lc
        .write()
        .unwrap()
        .initialize(id.to_owned(), conn_type, switch_uuid, force_relay);
    let session = Arc::new(session.clone());
    sessions::insert_session(session_id.to_owned(), conn_type, session.clone());

    Ok(session)
}

/// start a session with the given id.
///
/// # Arguments
///
/// * `id` - The identifier of the remote session with prefix. Regex: [\w]*[\_]*[\d]+
/// * `events2ui` - The events channel to ui.
pub fn session_start_(
    session_id: &SessionID,
    id: &str,
    event_stream: StreamSink<EventToUI>,
) -> ResultType<()> {
    // is_connected is used to indicate whether to start a peer connection. For two cases:
    // 1. "Move tab to new window"
    // 2. multi ui session within the same peer connnection.
    let mut is_connected = false;
    let mut is_found = false;
    for s in sessions::get_sessions() {
        if let Some(h) = s.session_handlers.write().unwrap().get_mut(session_id) {
            is_connected = h.event_stream.is_some();
            try_send_close_event(&h.event_stream);
            h.event_stream = Some(event_stream);
            is_found = true;
            break;
        }
    }
    if !is_found {
        bail!(
            "No session with peer id {}, session id: {}",
            id,
            session_id.to_string()
        );
    }

    if let Some(session) = sessions::get_session_by_session_id(session_id) {
        let is_first_ui_session = session.session_handlers.read().unwrap().len() == 1;
        if !is_connected && is_first_ui_session {
            #[cfg(feature = "flutter_texture_render")]
            log::info!(
                "Session {} start, render by flutter texture rgba plugin",
                id
            );
            #[cfg(not(feature = "flutter_texture_render"))]
            log::info!("Session {} start, render by flutter paint widget", id);

            let session = (*session).clone();
            std::thread::spawn(move || {
                let round = session.connection_round_state.lock().unwrap().new_round();
                io_loop(session, round);
            });
        }
        Ok(())
    } else {
        bail!("No session with peer id {}", id)
    }
}

#[inline]
fn try_send_close_event(event_stream: &Option<StreamSink<EventToUI>>) {
    if let Some(stream) = &event_stream {
        stream.add(EventToUI::Event("close".to_owned()));
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn update_text_clipboard_required() {
    let is_required = sessions::get_sessions()
        .iter()
        .any(|s| s.is_text_clipboard_required());
    Client::set_is_text_clipboard_required(is_required);
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn send_text_clipboard_msg(msg: Message) {
    for s in sessions::get_sessions() {
        if s.is_text_clipboard_required() {
            s.send(Data::Message(msg.clone()));
        }
    }
}

// Server Side
#[cfg(not(any(target_os = "ios")))]
pub mod connection_manager {
    use std::collections::HashMap;

    #[cfg(any(target_os = "android"))]
    use hbb_common::log;
    #[cfg(any(target_os = "android"))]
    use scrap::android::call_main_service_set_by_name;

    use crate::ui_cm_interface::InvokeUiCM;

    use super::GLOBAL_EVENT_STREAM;

    #[derive(Clone)]
    struct FlutterHandler {}

    impl InvokeUiCM for FlutterHandler {
        //TODO port_forward
        fn add_connection(&self, client: &crate::ui_cm_interface::Client) {
            let client_json = serde_json::to_string(&client).unwrap_or("".into());
            // send to Android service, active notification no matter UI is shown or not.
            #[cfg(any(target_os = "android"))]
            if let Err(e) =
                call_main_service_set_by_name("add_connection", Some(&client_json), None)
            {
                log::debug!("call_service_set_by_name fail,{}", e);
            }
            // send to UI, refresh widget
            self.push_event("add_connection", vec![("client", &client_json)]);
        }

        fn remove_connection(&self, id: i32, close: bool) {
            self.push_event(
                "on_client_remove",
                vec![("id", &id.to_string()), ("close", &close.to_string())],
            );
        }

        fn new_message(&self, id: i32, text: String) {
            self.push_event(
                "chat_server_mode",
                vec![("id", &id.to_string()), ("text", &text)],
            );
        }

        fn change_theme(&self, dark: String) {
            self.push_event("theme", vec![("dark", &dark)]);
        }

        fn change_language(&self) {
            self.push_event("language", vec![]);
        }

        fn show_elevation(&self, show: bool) {
            self.push_event("show_elevation", vec![("show", &show.to_string())]);
        }

        fn update_voice_call_state(&self, client: &crate::ui_cm_interface::Client) {
            let client_json = serde_json::to_string(&client).unwrap_or("".into());
            self.push_event("update_voice_call_state", vec![("client", &client_json)]);
        }

        fn file_transfer_log(&self, action: &str, log: &str) {
            self.push_event("cm_file_transfer_log", vec![(action, log)]);
        }
    }

    impl FlutterHandler {
        fn push_event(&self, name: &str, event: Vec<(&str, &str)>) {
            let mut h: HashMap<&str, &str> = event.iter().cloned().collect();
            debug_assert!(h.get("name").is_none());
            h.insert("name", name);

            if let Some(s) = GLOBAL_EVENT_STREAM.read().unwrap().get(super::APP_TYPE_CM) {
                s.add(serde_json::ser::to_string(&h).unwrap_or("".to_owned()));
            } else {
                println!(
                    "Push event {} failed. No {} event stream found.",
                    name,
                    super::APP_TYPE_CM
                );
            };
        }
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn start_cm_no_ui() {
        start_listen_ipc(false);
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn start_listen_ipc_thread() {
        start_listen_ipc(true);
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn start_listen_ipc(new_thread: bool) {
        use crate::ui_cm_interface::{start_ipc, ConnectionManager};

        #[cfg(target_os = "linux")]
        std::thread::spawn(crate::ipc::start_pa);

        let cm = ConnectionManager {
            ui_handler: FlutterHandler {},
        };
        if new_thread {
            std::thread::spawn(move || start_ipc(cm));
        } else {
            start_ipc(cm);
        }
    }

    #[inline]
    pub fn cm_init() {
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        start_listen_ipc_thread();
    }

    #[cfg(target_os = "android")]
    use hbb_common::tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

    #[cfg(target_os = "android")]
    pub fn start_channel(
        rx: UnboundedReceiver<crate::ipc::Data>,
        tx: UnboundedSender<crate::ipc::Data>,
    ) {
        use crate::ui_cm_interface::start_listen;
        let cm = crate::ui_cm_interface::ConnectionManager {
            ui_handler: FlutterHandler {},
        };
        std::thread::spawn(move || start_listen(cm, rx, tx));
    }
}

pub fn make_fd_flutter(id: i32, entries: &Vec<FileEntry>, only_count: bool) -> String {
    let mut m = serde_json::Map::new();
    m.insert("id".into(), json!(id));
    let mut a = vec![];
    let mut n: u64 = 0;
    for entry in entries {
        n += entry.size;
        if only_count {
            continue;
        }
        let mut e = serde_json::Map::new();
        e.insert("name".into(), json!(entry.name.to_owned()));
        let tmp = entry.entry_type.value();
        e.insert("type".into(), json!(if tmp == 0 { 1 } else { tmp }));
        e.insert("time".into(), json!(entry.modified_time as f64));
        e.insert("size".into(), json!(entry.size as f64));
        a.push(e);
    }
    if only_count {
        m.insert("num_entries".into(), json!(entries.len() as i32));
    } else {
        m.insert("entries".into(), json!(a));
    }
    m.insert("total_size".into(), json!(n as f64));
    serde_json::to_string(&m).unwrap_or("".into())
}

pub fn get_cur_session_id() -> SessionID {
    CUR_SESSION_ID.read().unwrap().clone()
}

pub fn get_cur_peer_id() -> String {
    sessions::get_peer_id_by_session_id(&get_cur_session_id(), ConnType::DEFAULT_CONN)
        .unwrap_or("".to_string())
}

pub fn set_cur_session_id(session_id: SessionID) {
    if get_cur_session_id() != session_id {
        *CUR_SESSION_ID.write().unwrap() = session_id;
    }
}

#[inline]
fn serialize_resolutions(resolutions: &Vec<Resolution>) -> String {
    #[derive(Debug, serde::Serialize)]
    struct ResolutionSerde {
        width: i32,
        height: i32,
    }

    let mut v = vec![];
    resolutions
        .iter()
        .map(|r| {
            v.push(ResolutionSerde {
                width: r.width,
                height: r.height,
            })
        })
        .count();
    serde_json::ser::to_string(&v).unwrap_or("".to_string())
}

fn char_to_session_id(c: *const char) -> ResultType<SessionID> {
    if c.is_null() {
        bail!("Session id ptr is null");
    }
    let cstr = unsafe { std::ffi::CStr::from_ptr(c as _) };
    let str = cstr.to_str()?;
    SessionID::from_str(str).map_err(|e| anyhow!("{:?}", e))
}

pub fn session_get_rgba_size(_session_id: SessionID, _display: usize) -> usize {
    #[cfg(not(feature = "flutter_texture_render"))]
    if let Some(session) = sessions::get_session_by_session_id(&_session_id) {
        return session
            .display_rgbas
            .read()
            .unwrap()
            .get(&_display)
            .map_or(0, |rgba| rgba.data.len());
    }
    0
}

#[no_mangle]
pub extern "C" fn session_get_rgba(session_uuid_str: *const char, display: usize) -> *const u8 {
    if let Ok(session_id) = char_to_session_id(session_uuid_str) {
        if let Some(s) = sessions::get_session_by_session_id(&session_id) {
            return s.ui_handler.get_rgba(display);
        }
    }

    std::ptr::null()
}

pub fn session_next_rgba(session_id: SessionID, display: usize) {
    if let Some(s) = sessions::get_session_by_session_id(&session_id) {
        return s.ui_handler.next_rgba(display);
    }
}

#[inline]
pub fn session_set_size(_session_id: SessionID, _display: usize, _width: usize, _height: usize) {
    #[cfg(feature = "flutter_texture_render")]
    for s in sessions::get_sessions() {
        if let Some(h) = s
            .ui_handler
            .session_handlers
            .write()
            .unwrap()
            .get_mut(&_session_id)
        {
            h.notify_rendered = false;
            h.renderer.set_size(_display, _width, _height);
            break;
        }
    }
}

#[inline]
pub fn session_register_texture(_session_id: SessionID, _display: usize, _ptr: usize) {
    #[cfg(feature = "flutter_texture_render")]
    for s in sessions::get_sessions() {
        if let Some(h) = s
            .ui_handler
            .session_handlers
            .read()
            .unwrap()
            .get(&_session_id)
        {
            h.renderer.register_texture(_display, _ptr);
            break;
        }
    }
}

#[inline]
pub fn push_session_event(session_id: &SessionID, name: &str, event: Vec<(&str, &str)>) {
    if let Some(s) = sessions::get_session_by_session_id(session_id) {
        s.push_event(name, event);
    }
}

#[inline]
pub fn push_global_event(channel: &str, event: String) -> Option<bool> {
    Some(GLOBAL_EVENT_STREAM.read().unwrap().get(channel)?.add(event))
}

#[inline]
pub fn get_global_event_channels() -> Vec<String> {
    GLOBAL_EVENT_STREAM
        .read()
        .unwrap()
        .keys()
        .cloned()
        .collect()
}

pub fn start_global_event_stream(s: StreamSink<String>, app_type: String) -> ResultType<()> {
    let app_type_values = app_type.split(",").collect::<Vec<&str>>();
    let mut lock = GLOBAL_EVENT_STREAM.write().unwrap();
    if !lock.contains_key(app_type_values[0]) {
        lock.insert(app_type_values[0].to_string(), s);
    } else {
        if let Some(_) = lock.insert(app_type.clone(), s) {
            log::warn!(
                "Global event stream of type {} is started before, but now removed",
                app_type
            );
        }
    }
    Ok(())
}

pub fn stop_global_event_stream(app_type: String) {
    let _ = GLOBAL_EVENT_STREAM.write().unwrap().remove(&app_type);
}

#[inline]
fn session_send_touch_scale(
    session_id: SessionID,
    v: &serde_json::Value,
    alt: bool,
    ctrl: bool,
    shift: bool,
    command: bool,
) {
    match v.get("v").and_then(|s| s.as_i64()) {
        Some(scale) => {
            if let Some(session) = sessions::get_session_by_session_id(&session_id) {
                session.send_touch_scale(scale as _, alt, ctrl, shift, command);
            }
        }
        None => {}
    }
}

#[inline]
fn session_send_touch_pan(
    session_id: SessionID,
    v: &serde_json::Value,
    pan_event: &str,
    alt: bool,
    ctrl: bool,
    shift: bool,
    command: bool,
) {
    match v.get("v") {
        Some(v) => match (
            v.get("x").and_then(|x| x.as_i64()),
            v.get("y").and_then(|y| y.as_i64()),
        ) {
            (Some(x), Some(y)) => {
                if let Some(session) = sessions::get_session_by_session_id(&session_id) {
                    session
                        .send_touch_pan_event(pan_event, x as _, y as _, alt, ctrl, shift, command);
                }
            }
            _ => {}
        },
        _ => {}
    }
}

fn session_send_touch_event(
    session_id: SessionID,
    v: &serde_json::Value,
    alt: bool,
    ctrl: bool,
    shift: bool,
    command: bool,
) {
    match v.get("t").and_then(|t| t.as_str()) {
        Some("scale") => session_send_touch_scale(session_id, v, alt, ctrl, shift, command),
        Some(pan_event) => {
            session_send_touch_pan(session_id, v, pan_event, alt, ctrl, shift, command)
        }
        _ => {}
    }
}

pub fn session_send_pointer(session_id: SessionID, msg: String) {
    if let Ok(m) = serde_json::from_str::<HashMap<String, serde_json::Value>>(&msg) {
        let alt = m.get("alt").is_some();
        let ctrl = m.get("ctrl").is_some();
        let shift = m.get("shift").is_some();
        let command = m.get("command").is_some();
        match (m.get("k"), m.get("v")) {
            (Some(k), Some(v)) => match k.as_str() {
                Some("touch") => session_send_touch_event(session_id, v, alt, ctrl, shift, command),
                _ => {}
            },
            _ => {}
        }
    }
}

#[inline]
pub fn session_on_waiting_for_image_dialog_show(session_id: SessionID) {
    for s in sessions::get_sessions() {
        if let Some(h) = s.session_handlers.write().unwrap().get_mut(&session_id) {
            h.on_waiting_for_image_dialog_show();
        }
    }
}

/// Hooks for session.
#[derive(Clone)]
pub enum SessionHook {
    OnSessionRgba(fn(String, &mut scrap::ImageRgb)),
}

#[inline]
pub fn get_cur_session() -> Option<FlutterSession> {
    sessions::get_session_by_session_id(&*CUR_SESSION_ID.read().unwrap())
}

// sessions mod is used to avoid the big lock of sessions' map.
pub mod sessions {
    #[cfg(feature = "flutter_texture_render")]
    use std::collections::HashSet;

    use super::*;

    lazy_static::lazy_static! {
        // peer -> peer session, peer session -> ui sessions
        static ref SESSIONS: RwLock<HashMap<(String, ConnType), FlutterSession>> = Default::default();
    }

    #[inline]
    pub fn get_session_count(peer_id: String, conn_type: ConnType) -> usize {
        SESSIONS
            .read()
            .unwrap()
            .get(&(peer_id, conn_type))
            .map(|s| s.ui_handler.session_handlers.read().unwrap().len())
            .unwrap_or(0)
    }

    #[inline]
    pub fn get_peer_id_by_session_id(id: &SessionID, conn_type: ConnType) -> Option<String> {
        SESSIONS
            .read()
            .unwrap()
            .iter()
            .find_map(|((peer_id, t), s)| {
                if *t == conn_type
                    && s.ui_handler
                        .session_handlers
                        .read()
                        .unwrap()
                        .contains_key(id)
                {
                    Some(peer_id.clone())
                } else {
                    None
                }
            })
    }

    #[inline]
    pub fn get_session_by_session_id(id: &SessionID) -> Option<FlutterSession> {
        SESSIONS
            .read()
            .unwrap()
            .values()
            .find(|s| {
                s.ui_handler
                    .session_handlers
                    .read()
                    .unwrap()
                    .contains_key(id)
            })
            .cloned()
    }

    #[inline]
    pub fn get_session_by_peer_id(peer_id: String, conn_type: ConnType) -> Option<FlutterSession> {
        SESSIONS.read().unwrap().get(&(peer_id, conn_type)).cloned()
    }

    #[inline]
    pub fn remove_session_by_session_id(id: &SessionID) -> Option<FlutterSession> {
        let mut remove_peer_key = None;
        for (peer_key, s) in SESSIONS.write().unwrap().iter_mut() {
            let mut write_lock = s.ui_handler.session_handlers.write().unwrap();
            let remove_ret = write_lock.remove(id);
            #[cfg(not(feature = "flutter_texture_render"))]
            if remove_ret.is_some() {
                if write_lock.is_empty() {
                    remove_peer_key = Some(peer_key.clone());
                }
                break;
            }
            #[cfg(feature = "flutter_texture_render")]
            match remove_ret {
                Some(_) => {
                    if write_lock.is_empty() {
                        remove_peer_key = Some(peer_key.clone());
                    } else {
                        check_remove_unused_displays(None, id, s, &write_lock);
                    }
                    break;
                }
                None => {}
            }
        }
        SESSIONS.write().unwrap().remove(&remove_peer_key?)
    }

    #[cfg(feature = "flutter_texture_render")]
    fn check_remove_unused_displays(
        current: Option<usize>,
        session_id: &SessionID,
        session: &FlutterSession,
        handlers: &HashMap<SessionID, SessionHandler>,
    ) {
        // Set capture displays if some are not used any more.
        let mut remains_displays = HashSet::new();
        if let Some(current) = current {
            remains_displays.insert(current);
        }
        for (k, h) in handlers.iter() {
            if k == session_id {
                continue;
            }
            remains_displays.extend(
                h.renderer
                    .map_display_sessions
                    .read()
                    .unwrap()
                    .keys()
                    .cloned(),
            );
        }
        if !remains_displays.is_empty() {
            session.capture_displays(
                vec![],
                vec![],
                remains_displays.iter().map(|d| *d as i32).collect(),
            );
        }
    }

    pub fn session_switch_display(is_desktop: bool, session_id: SessionID, value: Vec<i32>) {
        for s in SESSIONS.read().unwrap().values() {
            let read_lock = s.ui_handler.session_handlers.read().unwrap();
            if read_lock.contains_key(&session_id) {
                if value.len() == 1 {
                    // Switch display.
                    // This operation will also cause the peer to send a switch display message.
                    // The switch display message will contain `SupportedResolutions`, which is useful when changing resolutions.
                    s.switch_display(value[0]);

                    if !is_desktop {
                        s.capture_displays(vec![], vec![], value);
                    } else {
                        // Check if other displays are needed.
                        #[cfg(feature = "flutter_texture_render")]
                        if value.len() == 1 {
                            check_remove_unused_displays(
                                Some(value[0] as _),
                                &session_id,
                                &s,
                                &read_lock,
                            );
                        }
                    }
                } else {
                    // Try capture all displays.
                    s.capture_displays(vec![], vec![], value);
                }
                break;
            }
        }
    }

    #[inline]
    pub fn insert_session(session_id: SessionID, conn_type: ConnType, session: FlutterSession) {
        SESSIONS
            .write()
            .unwrap()
            .entry((session.get_id(), conn_type))
            .or_insert(session)
            .ui_handler
            .session_handlers
            .write()
            .unwrap()
            .insert(session_id, Default::default());
    }

    #[inline]
    pub fn insert_peer_session_id(
        peer_id: String,
        conn_type: ConnType,
        session_id: SessionID,
    ) -> bool {
        if let Some(s) = SESSIONS.read().unwrap().get(&(peer_id, conn_type)) {
            #[cfg(not(feature = "flutter_texture_render"))]
            let h = SessionHandler::default();
            #[cfg(feature = "flutter_texture_render")]
            let mut h = SessionHandler::default();
            #[cfg(feature = "flutter_texture_render")]
            {
                h.renderer.is_support_multi_ui_session = crate::common::is_support_multi_ui_session(
                    &s.ui_handler.peer_info.read().unwrap().version,
                );
            }
            let _ = s
                .ui_handler
                .session_handlers
                .write()
                .unwrap()
                .insert(session_id, h);
            true
        } else {
            false
        }
    }

    #[inline]
    pub fn get_sessions() -> Vec<FlutterSession> {
        SESSIONS.read().unwrap().values().cloned().collect()
    }

    #[inline]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub fn other_sessions_running(peer_id: String, conn_type: ConnType) -> bool {
        SESSIONS
            .read()
            .unwrap()
            .get(&(peer_id, conn_type))
            .map(|s| s.session_handlers.read().unwrap().len() != 0)
            .unwrap_or(false)
    }
}

pub(super) mod async_tasks {
    use hbb_common::{
        bail,
        tokio::{
            self, select,
            sync::mpsc::{unbounded_channel, UnboundedSender},
        },
        ResultType,
    };
    use std::{
        collections::HashMap,
        sync::{Arc, Mutex},
    };

    type TxQueryOnlines = UnboundedSender<Vec<String>>;
    lazy_static::lazy_static! {
        static ref TX_QUERY_ONLINES: Arc<Mutex<Option<TxQueryOnlines>>> = Default::default();
    }

    #[inline]
    pub fn start_flutter_async_runner() {
        std::thread::spawn(start_flutter_async_runner_);
    }

    #[allow(dead_code)]
    pub fn stop_flutter_async_runner() {
        let _ = TX_QUERY_ONLINES.lock().unwrap().take();
    }

    #[tokio::main(flavor = "current_thread")]
    async fn start_flutter_async_runner_() {
        let (tx_onlines, mut rx_onlines) = unbounded_channel::<Vec<String>>();
        TX_QUERY_ONLINES.lock().unwrap().replace(tx_onlines);

        loop {
            select! {
                ids = rx_onlines.recv() => {
                    match ids {
                        Some(_ids) => {
                            #[cfg(not(any(target_os = "ios")))]
                            crate::rendezvous_mediator::query_online_states(_ids, handle_query_onlines).await
                        }
                        None => {
                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn query_onlines(ids: Vec<String>) -> ResultType<()> {
        if let Some(tx) = TX_QUERY_ONLINES.lock().unwrap().as_ref() {
            let _ = tx.send(ids)?;
        } else {
            bail!("No tx_query_onlines");
        }
        Ok(())
    }

    fn handle_query_onlines(onlines: Vec<String>, offlines: Vec<String>) {
        let data = HashMap::from([
            ("name", "callback_query_onlines".to_owned()),
            ("onlines", onlines.join(",")),
            ("offlines", offlines.join(",")),
        ]);
        let _res = super::push_global_event(
            super::APP_TYPE_MAIN,
            serde_json::ser::to_string(&data).unwrap_or("".to_owned()),
        );
    }
}
