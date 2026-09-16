use eframe::egui::{self, Color32, RichText};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

const SOCKET: &str = "/run/umbra-update/backend.sock";
const INK: Color32 = Color32::from_rgb(7, 16, 51);
const CARD: Color32 = Color32::from_rgb(12, 25, 70);
const CARD_RAISED: Color32 = Color32::from_rgb(17, 33, 82);
const ACCENT: Color32 = Color32::from_rgb(157, 124, 255);
const BLUE: Color32 = Color32::from_rgb(80, 183, 245);
const MUTED: Color32 = Color32::from_rgb(164, 174, 205);
const BORDER: Color32 = Color32::from_rgb(48, 65, 120);
const DANGER: Color32 = Color32::from_rgb(255, 145, 166);

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

enum Event {
    Status(Result<UpdateStatus, String>),
    Checked(Result<UpdateStatus, String>),
    Installed(Result<UpdateStatus, String>),
    Proxy(Result<UpdateStatus, String>),
}

fn rpc(action: &'static str, extra: Value) -> Result<UpdateStatus, String> {
    let mut request = json!({"action": action});
    if let (Some(target), Some(fields)) = (request.as_object_mut(), extra.as_object()) {
        target.extend(fields.clone());
    }
    let mut stream = UnixStream::connect(SOCKET)
        .map_err(|error| format!("Update service unavailable: {error}"))?;
    stream
        .write_all(request.to_string().as_bytes())
        .map_err(|e| e.to_string())?;
    stream
        .shutdown(std::net::Shutdown::Write)
        .map_err(|e| e.to_string())?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|e| e.to_string())?;
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, body)| body)
        .unwrap_or(&response);
    let reply: Reply = serde_json::from_str(body).map_err(|_| body.trim().to_owned())?;
    if reply.ok {
        reply
            .status
            .ok_or_else(|| "Backend returned no update status".into())
    } else {
        Err(reply
            .error
            .unwrap_or_else(|| "Update request failed".into()))
    }
}

fn spawn_rpc(
    action: &'static str,
    extra: Value,
    tx: Sender<Event>,
    wrap: fn(Result<UpdateStatus, String>) -> Event,
) {
    thread::spawn(move || {
        let _ = tx.send(wrap(rpc(action, extra)));
    });
}

struct Updater {
    status: UpdateStatus,
    proxy_url: String,
    message: String,
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
                }
                Err(error) => self.message = error,
            }
        }
    }

    fn request(
        &mut self,
        action: &'static str,
        extra: Value,
        wrap: fn(Result<UpdateStatus, String>) -> Event,
    ) {
        self.busy = true;
        self.message.clear();
        spawn_rpc(action, extra, self.tx.clone(), wrap);
    }
}

impl eframe::App for Updater {
    fn update(&mut self, context: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_events();
        if self.busy {
            context.request_repaint_after(std::time::Duration::from_millis(250));
        }
        egui::CentralPanel::default().frame(egui::Frame::new().fill(INK).inner_margin(28)).show(context, |ui| {
            ui.label(RichText::new("SYSTEM UPDATE").strong().size(11.0).color(BLUE));
            ui.add_space(3.0);
            ui.label(RichText::new("Keep UmbraOS current.").size(28.0).strong().color(Color32::WHITE));
            ui.label(RichText::new("Updates are fetched from the official UmbraOS main branch and activated as a normal NixOS generation.").color(MUTED));
            ui.add_space(20.0);

            Self::card(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.vertical(|ui| {
                        ui.label(RichText::new("UPDATE STATUS").small().strong().color(BLUE));
                        ui.label(RichText::new(self.status.state.replace('_', " ")).size(21.0).strong());
                        ui.label(RichText::new(format!("Build / activation: {}", self.status.build_activation_state.replace('_', " "))).color(MUTED));
                    });
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.add_enabled(!self.busy, egui::Button::new("Install update")).clicked() {
                            self.request("INSTALL_UPDATE", json!({}), Event::Installed);
                        }
                        if ui.add_enabled(!self.busy, egui::Button::new("Check for updates")).clicked() {
                            self.request("CHECK_UPDATE", json!({}), Event::Checked);
                        }
                    });
                });
                ui.add_space(14.0);
                egui::Grid::new("revisions").num_columns(2).spacing([28.0, 7.0]).show(ui, |ui| {
                    ui.label(RichText::new("Installed revision").color(MUTED)); ui.monospace(Self::short_revision(&self.status.installed_revision)); ui.end_row();
                    ui.label(RichText::new("Available revision").color(MUTED)); ui.monospace(Self::short_revision(&self.status.available_revision)); ui.end_row();
                    if self.status.previous_revision.is_some() { ui.label(RichText::new("Previous revision").color(MUTED)); ui.monospace(Self::short_revision(&self.status.previous_revision)); ui.end_row(); }
                });
                if self.busy { ui.add_space(12.0); ui.spinner(); }
                if let Some(error) = &self.status.error { ui.add_space(12.0); ui.label(RichText::new(error).color(DANGER)); }
            });

            ui.add_space(14.0);
            Self::card(ui, |ui| {
                ui.label(RichText::new("Temporary proxy").size(17.0).strong());
                ui.label(RichText::new("Used only by this update service until it restarts. The value is not persisted.").small().color(MUTED));
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    ui.add_enabled(!self.busy, egui::TextEdit::singleline(&mut self.proxy_url).hint_text("http://host:port").desired_width(360.0));
                    if ui.add_enabled(!self.busy, egui::Button::new("Apply and test")).clicked() {
                        let url = self.proxy_url.trim().to_owned();
                        self.proxy_url = url.clone();
                        self.request("SET_UPDATE_PROXY", json!({"url":url}), Event::Proxy);
                    }
                    if ui.add_enabled(!self.busy && self.status.proxy_configured, egui::Button::new("Use direct connection")).clicked() {
                        self.proxy_url.clear();
                        self.request("SET_UPDATE_PROXY", json!({"url":""}), Event::Proxy);
                    }
                });
                ui.label(RichText::new(if self.status.proxy_configured { "Temporary proxy enabled" } else { "Direct connection" }).small().color(if self.status.proxy_configured { ACCENT } else { MUTED }));
            });

            if !self.message.is_empty() { ui.add_space(14.0); egui::Frame::new().fill(CARD_RAISED).corner_radius(8).inner_margin(12).show(ui, |ui| { ui.label(&self.message); }); }
        });
    }
}

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("UmbraOS Update")
            .with_inner_size([760.0, 610.0])
            .with_min_inner_size([620.0, 500.0]),
        ..Default::default()
    };
    eframe::run_native(
        "UmbraOS Update",
        options,
        Box::new(|creation| {
            let mut visuals = egui::Visuals::dark();
            visuals.panel_fill = INK;
            visuals.window_fill = INK;
            visuals.widgets.inactive.bg_fill = CARD_RAISED;
            visuals.widgets.inactive.bg_stroke = egui::Stroke::new(1.0_f32, BORDER);
            visuals.widgets.hovered.bg_fill = Color32::from_rgb(28, 47, 104);
            visuals.widgets.hovered.bg_stroke = egui::Stroke::new(1.0_f32, BLUE);
            visuals.widgets.active.bg_fill = Color32::from_rgb(65, 48, 125);
            visuals.widgets.active.bg_stroke = egui::Stroke::new(1.0_f32, ACCENT);
            creation.egui_ctx.set_visuals(visuals);
            Ok(Box::new(Updater::new(creation.egui_ctx.clone())))
        }),
    )
}
