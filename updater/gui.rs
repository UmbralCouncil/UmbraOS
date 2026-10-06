use eframe::egui::{self, Color32, RichText};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

const SOCKET: &str = "/run/umbra-update/backend.sock";
const INK: Color32 = Color32::from_rgb(7, 7, 7);
const CARD: Color32 = Color32::from_rgb(16, 14, 19);
const CARD_RAISED: Color32 = Color32::from_rgb(24, 20, 30);
const ACCENT: Color32 = Color32::from_rgb(139, 92, 246);
const BLUE: Color32 = Color32::from_rgb(185, 161, 255);
const MUTED: Color32 = Color32::from_rgb(150, 140, 164);
const BORDER: Color32 = Color32::from_rgb(41, 35, 48);
const SUCCESS: Color32 = Color32::from_rgb(99, 217, 162);
const DANGER: Color32 = Color32::from_rgb(255, 118, 146);

#[derive(Clone, Default, Deserialize)]
struct UpdateStatus {
    state: String,
    build_activation_state: String,
    installed_revision: Option<String>,
    available_revision: Option<String>,
    previous_revision: Option<String>,
    #[serde(default)]
    proxy_configured: bool,
    error: Option<String>,
}

#[derive(Deserialize)]
struct Reply {
    ok: bool,
    status: Option<UpdateStatus>,
    error: Option<String>,
}

struct RpcError {
    message: String,
    status: Option<UpdateStatus>,
}

enum Event {
    Status(Result<UpdateStatus, RpcError>),
    Checked(Result<UpdateStatus, RpcError>),
    Installed(Result<UpdateStatus, RpcError>),
    Proxy(Result<UpdateStatus, RpcError>),
}

fn rpc(action: &'static str, extra: Value) -> Result<UpdateStatus, RpcError> {
    let mut request = json!({"action": action});
    if let (Some(target), Some(fields)) = (request.as_object_mut(), extra.as_object()) {
        target.extend(fields.clone());
    }
    let mut stream = UnixStream::connect(SOCKET)
        .map_err(|error| RpcError { message: format!("Update service unavailable: {error}"), status: None })?;
    stream
        .write_all(request.to_string().as_bytes())
        .map_err(|e| RpcError { message: e.to_string(), status: None })?;
    stream
        .shutdown(std::net::Shutdown::Write)
        .map_err(|e| RpcError { message: e.to_string(), status: None })?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|e| RpcError { message: e.to_string(), status: None })?;
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, body)| body)
        .unwrap_or(&response);
    let reply: Reply = serde_json::from_str(body).map_err(|_| RpcError { message: body.trim().to_owned(), status: None })?;
    if reply.ok {
        reply
            .status
            .ok_or_else(|| RpcError { message: "Backend returned no update status".into(), status: None })
    } else {
        Err(RpcError {
            message: reply.error.unwrap_or_else(|| "Update request failed".into()),
            status: reply.status,
        })
    }
}

fn spawn_rpc(
    action: &'static str,
    extra: Value,
    tx: Sender<Event>,
    wrap: fn(Result<UpdateStatus, RpcError>) -> Event,
) {
    thread::spawn(move || {
        let _ = tx.send(wrap(rpc(action, extra)));
    });
}

struct Updater {
    status: UpdateStatus,
    proxy_url: String,
    message: String,
    message_is_error: bool,
    busy: bool,
    tx: Sender<Event>,
    rx: Receiver<Event>,
}

impl Updater {
    fn new(context: egui::Context) -> Self {
        let (tx, rx) = mpsc::channel();
        let repaint = context.clone();
        let initial_tx = tx.clone();
        thread::spawn(move || {
            let result = rpc("GET_UPDATE_STATUS", json!({}));
            let _ = initial_tx.send(Event::Status(result));
            repaint.request_repaint();
        });
        Self {
            status: UpdateStatus::default(),
            proxy_url: String::new(),
            message: String::new(),
            message_is_error: false,
            busy: false,
            tx,
            rx,
        }
    }

    fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
        egui::Frame::new()
            .fill(CARD)
            .stroke(egui::Stroke::new(1.0_f32, BORDER))
            .corner_radius(egui::CornerRadius::same(10))
            .inner_margin(egui::Margin::same(16))
            .show(ui, add)
            .inner
    }

    fn short_revision(value: &Option<String>) -> &str {
        value
            .as_deref()
            .map(|revision| &revision[..revision.len().min(12)])
            .unwrap_or("Unknown")
    }

    fn handle_events(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            self.busy = false;
            let (result, success) = match event {
                Event::Status(result) => (result, "Status refreshed"),
                Event::Checked(result) => (result, "Update check complete"),
                Event::Installed(result) => (result, "UmbraOS update complete"),
                Event::Proxy(result) => (result, "Temporary proxy configuration applied"),
            };
            match result {
                Ok(status) => {
                    self.status = status;
                    self.message = success.into();
                    self.message_is_error = false;
                }
                Err(error) => {
                    if let Some(status) = error.status { self.status = status; }
                    self.message = error.message;
                    self.message_is_error = true;
                }
            }
        }
    }

    fn request(
        &mut self,
        action: &'static str,
        extra: Value,
        wrap: fn(Result<UpdateStatus, RpcError>) -> Event,
    ) {
        self.busy = true;
        self.message.clear();
        self.message_is_error = false;
        spawn_rpc(action, extra, self.tx.clone(), wrap);
    }

    fn state_title(&self) -> String {
        match self.status.state.as_str() {
            "" | "idle" => "Ready to check".into(),
            "checking" => "Checking for updates…".into(),
            "up_to_date" => "Your system is up to date".into(),
            "update_available" => "An update is available".into(),
            state => state.replace('_', " "),
        }
    }

    fn state_color(&self) -> Color32 {
        if self.status.error.is_some() || self.message_is_error { DANGER }
        else if self.status.state == "up_to_date" { SUCCESS }
        else { ACCENT }
    }

    fn primary_button(label: &str) -> egui::Button<'_> {
        egui::Button::new(RichText::new(label).color(Color32::WHITE).strong())
            .fill(ACCENT)
            .stroke(egui::Stroke::new(1.0_f32, Color32::from_rgb(168, 120, 255)))
            .corner_radius(8)
            .min_size(egui::vec2(148.0, 40.0))
    }

    fn status_mark(ui: &mut egui::Ui, color: Color32, busy: bool, complete: bool) {
        let (rect, _) = ui.allocate_exact_size(egui::vec2(18.0, 18.0), egui::Sense::hover());
        let painter = ui.painter();
        let stroke = egui::Stroke::new(2.0_f32, color);
        if busy {
            painter.circle_stroke(rect.center(), 7.0, stroke);
            painter.line_segment([rect.center(), egui::pos2(rect.right() - 1.0, rect.top() + 4.0)], stroke);
        } else if complete {
            painter.line_segment([egui::pos2(rect.left() + 2.0, rect.center().y), egui::pos2(rect.left() + 7.0, rect.bottom() - 3.0)], stroke);
            painter.line_segment([egui::pos2(rect.left() + 7.0, rect.bottom() - 3.0), egui::pos2(rect.right() - 1.0, rect.top() + 2.0)], stroke);
        } else {
            painter.circle_filled(rect.center(), 4.0, color);
        }
    }

    fn connection_mark(ui: &mut egui::Ui, color: Color32) {
        let (rect, _) = ui.allocate_exact_size(egui::vec2(10.0, 10.0), egui::Sense::hover());
        ui.painter().circle_filled(rect.center(), 3.0, color);
    }
}

impl eframe::App for Updater {
    fn update(&mut self, context: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_events();
        if self.busy {
            context.request_repaint_after(std::time::Duration::from_millis(250));
        }
        egui::CentralPanel::default().frame(egui::Frame::new().fill(INK).inner_margin(0)).show(context, |ui| {
            egui::Frame::new().fill(Color32::from_rgb(12, 10, 15)).stroke(egui::Stroke::new(1.0_f32, BORDER)).inner_margin(egui::Margin::symmetric(30, 17)).show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.vertical(|ui| {
                        ui.label(RichText::new("UmbraOS").color(Color32::WHITE).size(17.0).strong());
                        ui.label(RichText::new("SYSTEM UPDATE").color(BLUE).size(9.0).strong());
                    });
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.label(RichText::new("Official update channel  •  NixOS generations").color(MUTED).size(11.0));
                    });
                });
            });

            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                ui.add_space(34.0);
                let content_width = ui.available_width().min(900.0);
                let gutter = ((ui.available_width() - content_width) / 2.0).max(24.0);
                ui.horizontal(|ui| {
                    ui.add_space(gutter);
                    ui.vertical(|ui| {
                        ui.set_width(content_width);
                        ui.label(RichText::new("SYSTEM UPDATE").strong().size(10.0).color(BLUE));
                        ui.add_space(4.0);
                        ui.label(RichText::new("Keep UmbraOS current.").size(30.0).strong().color(Color32::WHITE));
                        ui.add_space(3.0);
                        ui.label(RichText::new("Safely check, build, and activate the latest UmbraOS generation.").size(14.0).color(MUTED));
                        ui.add_space(24.0);

                        Self::card(ui, |ui| {
                            ui.horizontal(|ui| {
                                let color = self.state_color();
                                egui::Frame::new().fill(color.gamma_multiply(0.13)).stroke(egui::Stroke::new(1.0_f32, color.gamma_multiply(0.65))).corner_radius(24).inner_margin(11).show(ui, |ui| {
                                    Self::status_mark(ui, color, self.busy, self.status.state == "up_to_date");
                                });
                                ui.add_space(5.0);
                                ui.vertical(|ui| {
                                    ui.label(RichText::new("UPDATE STATUS").small().strong().color(BLUE));
                                    ui.label(RichText::new(self.state_title()).size(22.0).strong().color(Color32::WHITE));
                                    ui.label(RichText::new(format!("Build and activation: {}", self.status.build_activation_state.replace('_', " "))).color(MUTED));
                                });
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                    if ui.add_enabled(!self.busy && self.status.state == "update_available", Self::primary_button("Install update")).clicked() {
                                        self.request("INSTALL_UPDATE", json!({}), Event::Installed);
                                    }
                                    if ui.add_enabled(!self.busy, egui::Button::new("Check again").min_size(egui::vec2(112.0, 40.0))).clicked() {
                                        self.request("CHECK_UPDATE", json!({}), Event::Checked);
                                    }
                                });
                            });
                            ui.add_space(18.0);
                            ui.separator();
                            ui.add_space(12.0);
                            ui.columns(3, |columns| {
                                for (column, (label, revision)) in columns.iter_mut().zip([
                                    ("INSTALLED", Self::short_revision(&self.status.installed_revision)),
                                    ("AVAILABLE", Self::short_revision(&self.status.available_revision)),
                                    ("PREVIOUS", Self::short_revision(&self.status.previous_revision)),
                                ]) {
                                    column.label(RichText::new(label).color(MUTED).size(9.0).strong());
                                    column.add_space(4.0);
                                    column.label(RichText::new(revision).color(Color32::from_rgb(216, 206, 232)).monospace().size(13.0));
                                }
                            });
                            if let Some(error) = &self.status.error { ui.add_space(14.0); ui.label(RichText::new(error).color(DANGER)); }
                        });

                        ui.add_space(16.0);
                        Self::card(ui, |ui| {
                            ui.horizontal(|ui| {
                                ui.vertical(|ui| {
                                    ui.label(RichText::new("NETWORK").small().strong().color(BLUE));
                                    ui.label(RichText::new("Temporary proxy").size(18.0).strong());
                                    ui.label(RichText::new("Optional, session-only routing for restricted networks.").small().color(MUTED));
                                });
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                    let (label, color) = if self.status.proxy_configured { ("Proxy active", ACCENT) } else { ("Direct connection", SUCCESS) };
                                    ui.label(RichText::new(label).color(color).small().strong());
                                    Self::connection_mark(ui, color);
                                });
                            });
                            ui.add_space(13.0);
                            ui.horizontal(|ui| {
                                let button_width = 124.0;
                                ui.add_enabled_ui(!self.busy, |ui| {
                                    ui.add_sized([ui.available_width() - button_width - 10.0, 38.0], egui::TextEdit::singleline(&mut self.proxy_url).hint_text("http://host:port"));
                                });
                                if ui.add_enabled(!self.busy, egui::Button::new("Apply & test").min_size(egui::vec2(button_width, 38.0))).clicked() {
                                    let url = self.proxy_url.trim().to_owned();
                                    self.proxy_url = url.clone();
                                    self.request("SET_UPDATE_PROXY", json!({"url":url}), Event::Proxy);
                                }
                            });
                            if self.status.proxy_configured {
                                ui.add_space(8.0);
                                if ui.add_enabled(!self.busy, egui::Button::new("Return to direct connection")).clicked() {
                                    self.proxy_url.clear();
                                    self.request("SET_UPDATE_PROXY", json!({"url":""}), Event::Proxy);
                                }
                            }
                        });

                        if !self.message.is_empty() {
                            ui.add_space(14.0);
                            let color = if self.message_is_error { DANGER } else { SUCCESS };
                            egui::Frame::new().fill(color.gamma_multiply(0.09)).stroke(egui::Stroke::new(1.0_f32, color.gamma_multiply(0.45))).corner_radius(8).inner_margin(12).show(ui, |ui| {
                                ui.horizontal(|ui| {
                                    Self::status_mark(ui, color, false, !self.message_is_error);
                                    ui.label(RichText::new(&self.message).color(color));
                                });
                            });
                        }
                        ui.add_space(28.0);
                        ui.horizontal(|ui| {
                            ui.label(RichText::new("Updates create a new generation. Your previous generation remains available for rollback.").color(MUTED).size(10.0));
                        });
                        ui.add_space(30.0);
                    });
                });
            });
        });
    }
}

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("UmbraOS Update")
            .with_inner_size([980.0, 720.0])
            .with_min_inner_size([760.0, 600.0])
            .with_fullscreen(true),
        ..Default::default()
    };
    eframe::run_native(
        "UmbraOS Update",
        options,
        Box::new(|creation| {
            let mut visuals = egui::Visuals::dark();
            visuals.panel_fill = INK;
            visuals.window_fill = INK;
            visuals.extreme_bg_color = INK;
            visuals.faint_bg_color = CARD_RAISED;
            visuals.selection.bg_fill = Color32::from_rgb(70, 44, 112);
            visuals.selection.stroke.color = Color32::WHITE;
            visuals.widgets.inactive.bg_fill = CARD_RAISED;
            visuals.widgets.inactive.bg_stroke = egui::Stroke::new(1.0_f32, BORDER);
            visuals.widgets.hovered.bg_fill = Color32::from_rgb(31, 25, 39);
            visuals.widgets.hovered.bg_stroke = egui::Stroke::new(1.0_f32, BLUE);
            visuals.widgets.active.bg_fill = Color32::from_rgb(74, 47, 104);
            visuals.widgets.active.bg_stroke = egui::Stroke::new(1.0_f32, ACCENT);
            creation.egui_ctx.set_visuals(visuals);
            let mut style = (*creation.egui_ctx.style()).clone();
            style.spacing.item_spacing = egui::vec2(10.0, 9.0);
            style.spacing.button_padding = egui::vec2(14.0, 8.0);
            style.spacing.interact_size = egui::vec2(44.0, 34.0);
            style.text_styles.insert(egui::TextStyle::Body, egui::FontId::proportional(14.0));
            style.text_styles.insert(egui::TextStyle::Button, egui::FontId::proportional(13.0));
            creation.egui_ctx.set_style(style);
            Ok(Box::new(Updater::new(creation.egui_ctx.clone())))
        }),
    )
}
