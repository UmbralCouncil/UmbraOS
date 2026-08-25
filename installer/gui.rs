use eframe::egui::{self, Color32, RichText};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

const SOCKET: &str = "/run/umbra-installer/backend.sock";
const LOG: &str = "/tmp/umbra-installer.log";

#[derive(Clone, Default, Deserialize)]
struct Device {
    path: String,
    #[serde(rename = "type")]
    kind: String,
    size: Option<u64>,
    model: Option<String>,
    fstype: Option<String>,
    parttype: Option<String>,
    #[serde(default)]
    children: Vec<Device>,
}

#[derive(Deserialize)]
struct DisksResponse {
    #[serde(default)]
    blockdevices: Vec<Device>,
    #[serde(default)]
    umbra_live_disk: String,
}

#[derive(Clone, Deserialize)]
struct Network {
    connected: bool,
    ssid: String,
    signal: u8,
    security: String,
}

#[derive(Deserialize)]
struct WifiResponse { networks: Vec<Network> }

#[derive(Deserialize)]
struct TimeResponse {
    timezone: String,
    synchronized: bool,
    timezones: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum InstallMode { Erase, Manual }

enum Event {
    Disks(Result<DisksResponse, String>),
    Wifi(Result<WifiResponse, String>),
    WifiConnected(Result<String, String>),
    Time(Result<TimeResponse, String>),
    TimeSet(Result<String, String>),
    Installed(Result<String, String>),
    Log(String),
}

struct Installer {
    token: String,
    step: usize,
    mode: InstallMode,
    disks: Vec<Device>,
    target_disk: String,
    root: String,
    esp: String,
    networks: Vec<Network>,
    wifi_ssid: String,
    wifi_password: String,
    wifi_status: String,
    timezone: String,
    timezones: Vec<String>,
    time_filter: String,
    time_status: String,
    username: String,
    hostname: String,
    password: String,
    password2: String,
    confirmation: String,
    busy: bool,
    installing: bool,
    result: String,
    logs: Vec<String>,
    tx: Sender<Event>,
    rx: Receiver<Event>,
}

fn rpc(token: &str, action: &str, body: Value) -> Result<Value, String> {
    let request = json!({
        "token": token,
        "action": action,
        "method": if body.is_null() { "GET" } else { "POST" },
        "body": if body.is_null() { json!({}) } else { body },
    });
    let mut stream = UnixStream::connect(SOCKET).map_err(|error| format!("backend unavailable: {error}"))?;
    stream.write_all(request.to_string().as_bytes()).map_err(|error| error.to_string())?;
    stream.shutdown(std::net::Shutdown::Write).map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream.read_to_string(&mut response).map_err(|error| error.to_string())?;
    let (headers, payload) = response.split_once("\r\n\r\n").ok_or("invalid backend response")?;
    if headers.lines().any(|line| line.starts_with("Status:") && !line.contains(" 200 ")) {
        return Err(payload.trim().to_owned());
    }
    serde_json::from_str(payload).map_err(|_| payload.trim().to_owned())
}

fn spawn_rpc<T, F>(token: String, action: &'static str, body: Value, tx: Sender<Event>, wrap: F)
where
    T: for<'de> Deserialize<'de> + Send + 'static,
    F: FnOnce(Result<T, String>) -> Event + Send + 'static,
{
    thread::spawn(move || {
        let result = rpc(&token, action, body).and_then(|value| serde_json::from_value(value).map_err(|e| e.to_string()));
        let _ = tx.send(wrap(result));
    });
}

impl Installer {
    fn new(token: String, context: egui::Context) -> Self {
        let (tx, rx) = mpsc::channel();
        let repaint = context.clone();
        let log_tx = tx.clone();
        thread::spawn(move || {
            let child = Command::new("tail").args(["-n", "80", "-f", LOG]).stdout(Stdio::piped()).spawn();
            if let Ok(mut child) = child {
                if let Some(stdout) = child.stdout.take() {
                    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                        let _ = log_tx.send(Event::Log(line));
                        repaint.request_repaint();
                    }
                }
            }
        });
        let mut app = Self {
            token, step: 0, mode: InstallMode::Erase, disks: vec![], target_disk: String::new(),
            root: String::new(), esp: String::new(), networks: vec![], wifi_ssid: String::new(),
            wifi_password: String::new(), wifi_status: "Scanning…".into(), timezone: "America/New_York".into(),
            timezones: vec![], time_filter: String::new(), time_status: "Checking…".into(),
            username: "umbra".into(), hostname: "umbra".into(), password: String::new(),
            password2: String::new(), confirmation: String::new(), busy: false, installing: false,
            result: String::new(), logs: vec![], tx, rx,
        };
        app.refresh_setup();
        app
    }

    fn refresh_setup(&mut self) {
        spawn_rpc::<WifiResponse, _>(self.token.clone(), "wifi", Value::Null, self.tx.clone(), Event::Wifi);
        spawn_rpc::<TimeResponse, _>(self.token.clone(), "time", Value::Null, self.tx.clone(), Event::Time);
    }

    fn refresh_disks(&mut self) {
        self.busy = true;
        spawn_rpc::<DisksResponse, _>(self.token.clone(), "disks", Value::Null, self.tx.clone(), Event::Disks);
    }

    fn flatten(devices: &[Device]) -> Vec<&Device> {
        let mut result = Vec::new();
        for device in devices { result.push(device); result.extend(Self::flatten(&device.children)); }
        result
    }

    fn target(&self) -> &str { if self.mode == InstallMode::Erase { &self.target_disk } else { &self.root } }
    fn expected_confirmation(&self) -> String {
        format!("{} {}", if self.mode == InstallMode::Erase { "ERASE" } else { "FORMAT" }, self.target())
    }

    fn handle_events(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                Event::Disks(result) => { self.busy = false; match result { Ok(data) => {
                    self.disks = data.blockdevices.into_iter().filter(|d| d.path != data.umbra_live_disk).collect();
                    if self.target_disk.is_empty() { self.target_disk = self.disks.iter().find(|d| d.kind == "disk").map(|d| d.path.clone()).unwrap_or_default(); }
                }, Err(error) => self.result = error } }
                Event::Wifi(result) => match result { Ok(data) => { self.networks = data.networks; if let Some(n) = self.networks.iter().find(|n| n.connected) { self.wifi_ssid = n.ssid.clone(); self.wifi_status = format!("Connected to {}", n.ssid); } else { self.wifi_status = "Select a network to connect".into(); } }, Err(error) => self.wifi_status = error },
                Event::WifiConnected(result) => { self.busy = false; match result { Ok(ssid) => { self.wifi_password.clear(); self.wifi_status = format!("Connected to {ssid}"); }, Err(error) => self.wifi_status = error } }
                Event::Time(result) => match result { Ok(data) => { self.timezone = data.timezone; self.timezones = data.timezones; self.time_status = if data.synchronized { "Clock synchronized" } else { "Waiting for NTP" }.into(); }, Err(error) => self.time_status = error },
                Event::TimeSet(result) => { self.busy = false; match result { Ok(zone) => self.time_status = format!("{zone}; NTP enabled"), Err(error) => self.time_status = error } }
                Event::Installed(result) => { self.busy = false; self.installing = false; self.result = result.unwrap_or_else(|e| e); }
                Event::Log(line) => { self.logs.push(line); if self.logs.len() > 500 { self.logs.drain(..100); } }
            }
        }
    }

    fn heading(ui: &mut egui::Ui, kicker: &str, title: &str) {
        ui.label(RichText::new(kicker).small().color(Color32::from_rgb(184, 179, 255)));
        ui.heading(title);
        ui.add_space(10.0);
    }

    fn setup(&mut self, ui: &mut egui::Ui) {
        Self::heading(ui, "NETWORK & TIME", "Get the live system ready.");
        ui.columns(2, |columns| {
            columns[0].group(|ui| {
                ui.horizontal(|ui| { ui.strong("Wi-Fi"); if ui.button("Scan").clicked() { spawn_rpc::<WifiResponse, _>(self.token.clone(), "wifi", Value::Null, self.tx.clone(), Event::Wifi); } });
                egui::ComboBox::from_id_salt("wifi").selected_text(if self.wifi_ssid.is_empty() { "Select a network" } else { &self.wifi_ssid }).show_ui(ui, |ui| {
                    for network in &self.networks { ui.selectable_value(&mut self.wifi_ssid, network.ssid.clone(), format!("{}  {}%  {}", network.ssid, network.signal, if network.security.is_empty() { "Open" } else { &network.security })); }
                });
                ui.label("Password"); ui.add(egui::TextEdit::singleline(&mut self.wifi_password).password(true));
                if ui.add_enabled(!self.busy && !self.wifi_ssid.is_empty(), egui::Button::new("Connect")).clicked() {
                    self.busy = true; let ssid = self.wifi_ssid.clone();
                    spawn_rpc::<Value, _>(self.token.clone(), "wifi-connect", json!({"ssid": ssid, "password": self.wifi_password}), self.tx.clone(), move |r| Event::WifiConnected(r.map(|_| ssid)));
                }
                ui.label(RichText::new(&self.wifi_status).small());
            });
            columns[1].group(|ui| {
                ui.strong("Date & time"); ui.label("Time zone");
                ui.text_edit_singleline(&mut self.time_filter);
                let search = self.time_filter.to_lowercase();
                egui::ComboBox::from_id_salt("timezone").selected_text(&self.timezone).show_ui(ui, |ui| {
                    for zone in self.timezones.iter().filter(|z| search.is_empty() || z.to_lowercase().contains(&search)).take(100) { ui.selectable_value(&mut self.timezone, zone.clone(), zone); }
                });
                if ui.add_enabled(!self.busy, egui::Button::new("Apply timezone & enable NTP")).clicked() {
                    self.busy = true; let zone = self.timezone.clone();
                    spawn_rpc::<Value, _>(self.token.clone(), "time-set", json!({"timezone": zone}), self.tx.clone(), move |r| Event::TimeSet(r.map(|_| zone)));
                }
                ui.label(RichText::new(&self.time_status).small());
            });
        });
        ui.add_space(12.0); ui.label("Ethernet works automatically. Accurate time is required for secure package downloads.");
    }

    fn mode(&mut self, ui: &mut egui::Ui) {
        Self::heading(ui, "INSTALLATION MODE", "Choose how UmbraOS uses your disk.");
        ui.horizontal(|ui| {
            ui.selectable_value(&mut self.mode, InstallMode::Erase, "Erase an entire disk");
            ui.selectable_value(&mut self.mode, InstallMode::Manual, "Manual / dual boot");
        });
        ui.add_space(16.0);
        ui.group(|ui| match self.mode {
            InstallMode::Erase => { ui.strong("Use an entire disk"); ui.label("The selected disk is erased and receives a 1 GiB EFI partition plus a Btrfs root."); }
            InstallMode::Manual => { ui.strong("Reuse prepared partitions"); ui.label("Assign a root partition and an existing FAT32 EFI partition. The installer never resizes partitions."); }
        });
    }

    fn storage(&mut self, ui: &mut egui::Ui) {
        Self::heading(ui, "STORAGE", "Set up the installation target.");
        if ui.button("Refresh devices").clicked() { self.refresh_disks(); }
        let all = Self::flatten(&self.disks);
        if self.mode == InstallMode::Erase {
            egui::ComboBox::from_label("Installation disk").selected_text(&self.target_disk).show_ui(ui, |ui| {
                for disk in all.iter().filter(|d| d.kind == "disk") { ui.selectable_value(&mut self.target_disk, disk.path.clone(), format!("{} — {} — {:.1} GiB", disk.path, disk.model.as_deref().unwrap_or("Disk"), disk.size.unwrap_or(0) as f64 / 1_073_741_824.0)); }
            });
            ui.colored_label(Color32::from_rgb(255, 170, 170), "The selected disk will be completely erased.");
        } else {
            egui::Grid::new("parts").striped(true).show(ui, |ui| {
                ui.strong("Partition"); ui.strong("Size"); ui.strong("Filesystem"); ui.strong("Root"); ui.strong("EFI"); ui.end_row();
                for part in all.iter().filter(|d| d.kind == "part") {
                    ui.label(&part.path); ui.label(format!("{:.1} GiB", part.size.unwrap_or(0) as f64 / 1_073_741_824.0)); ui.label(part.fstype.as_deref().unwrap_or("Unformatted"));
                    ui.radio_value(&mut self.root, part.path.clone(), "");
                    let efi = part.fstype.as_deref() == Some("vfat") || part.parttype.as_deref() == Some("c12a7328-f81f-11d2-ba4b-00a0c93ec93b");
                    ui.add_enabled_ui(efi, |ui| { ui.radio_value(&mut self.esp, part.path.clone(), ""); }); ui.end_row();
                }
            });
        }
    }

    fn identity(&mut self, ui: &mut egui::Ui) {
        Self::heading(ui, "IDENTITY", "Make this system yours.");
        egui::Grid::new("identity").num_columns(2).spacing([20.0, 10.0]).show(ui, |ui| {
            ui.label("Username"); ui.text_edit_singleline(&mut self.username); ui.end_row();
            ui.label("Hostname"); ui.text_edit_singleline(&mut self.hostname); ui.end_row();
            ui.label("Password"); ui.add(egui::TextEdit::singleline(&mut self.password).password(true)); ui.end_row();
            ui.label("Confirm password"); ui.add(egui::TextEdit::singleline(&mut self.password2).password(true)); ui.end_row();
        });
    }

    fn review(&mut self, ui: &mut egui::Ui) {
        Self::heading(ui, "REVIEW", "This is the point of no return.");
        egui::Grid::new("review").striped(true).show(ui, |ui| {
            for (label, value) in [("Mode", if self.mode == InstallMode::Erase { "Erase whole disk" } else { "Manual / dual boot" }), ("Target", self.target()), ("User", &self.username), ("Hostname", &self.hostname), ("Time zone", &self.timezone)] { ui.label(label); ui.strong(value); ui.end_row(); }
        });
        let expected = self.expected_confirmation();
        ui.add_space(8.0); ui.label(format!("Type {expected} to confirm")); ui.text_edit_singleline(&mut self.confirmation);
        if self.installing || !self.logs.is_empty() {
            ui.separator(); ui.label(RichText::new("/tmp/umbra-installer.log (tail -f)").monospace());
            egui::ScrollArea::vertical().stick_to_bottom(true).max_height(190.0).show(ui, |ui| { for line in &self.logs { ui.label(RichText::new(line).monospace().small()); } });
        }
        if !self.result.is_empty() { ui.separator(); ui.label(&self.result); }
    }

    fn validate_step(&self) -> Result<(), String> {
        match self.step {
            0 if self.timezone.is_empty() => Err("Select a timezone".into()),
            2 if self.target().is_empty() => Err("Select an installation target".into()),
            2 if self.mode == InstallMode::Manual && (self.esp.is_empty() || self.esp == self.root) => Err("Select different root and EFI partitions".into()),
            3 if self.username.is_empty() || self.hostname.is_empty() => Err("Username and hostname are required".into()),
            3 if self.password.len() < 8 => Err("Password must be at least 8 characters".into()),
            3 if self.password != self.password2 => Err("Passwords do not match".into()),
            _ => Ok(()),
        }
    }

    fn install(&mut self) {
        let expected = self.expected_confirmation();
        if self.confirmation != expected { self.result = "Confirmation text does not match".into(); return; }
        self.busy = true; self.installing = true; self.result.clear();
        let body = json!({ "mode": if self.mode == InstallMode::Erase { "erase" } else { "manual" }, "disk": self.target_disk, "root": self.root, "esp": self.esp, "username": self.username, "hostname": self.hostname, "timezone": self.timezone, "password": self.password, "confirmation": self.confirmation });
        spawn_rpc::<Value, _>(self.token.clone(), "install", body, self.tx.clone(), |result| Event::Installed(result.map(|value| value.get("message").and_then(Value::as_str).unwrap_or("Installation complete").to_owned())));
    }
}

impl eframe::App for Installer {
    fn update(&mut self, context: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_events();
        egui::TopBottomPanel::top("header").show(context, |ui| { ui.horizontal(|ui| { ui.heading("UmbraOS"); ui.label("Installer"); ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| { ui.label(format!("{} / 5", self.step + 1)); }); }); });
        egui::CentralPanel::default().show(context, |ui| match self.step { 0 => self.setup(ui), 1 => self.mode(ui), 2 => self.storage(ui), 3 => self.identity(ui), _ => self.review(ui) });
        egui::TopBottomPanel::bottom("footer").show(context, |ui| { ui.horizontal(|ui| {
            if ui.add_enabled(self.step > 0 && !self.busy, egui::Button::new("Back")).clicked() { self.step -= 1; }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let label = if self.step == 4 { "Install UmbraOS" } else { "Continue" };
                if ui.add_enabled(!self.busy, egui::Button::new(label)).clicked() {
                    if self.step == 4 { self.install(); } else if let Err(error) = self.validate_step() { self.result = error; } else {
                        self.result.clear();
                        if self.step == 0 {
                            self.busy = true;
                            let zone = self.timezone.clone();
                            spawn_rpc::<Value, _>(self.token.clone(), "time-set", json!({"timezone": zone}), self.tx.clone(), move |r| Event::TimeSet(r.map(|_| zone)));
                        }
                        self.step += 1;
                        if self.step == 2 && self.disks.is_empty() { self.refresh_disks(); }
                    }
                }
            });
        }); });
        if self.busy { context.request_repaint_after(std::time::Duration::from_millis(100)); }
    }
}

fn main() -> eframe::Result {
    let token = std::env::args().nth(1).expect("usage: umbra-installer-ui TOKEN");
    let options = eframe::NativeOptions { viewport: egui::ViewportBuilder::default().with_title("Install UmbraOS").with_inner_size([920.0, 680.0]).with_min_inner_size([800.0, 560.0]), ..Default::default() };
    eframe::run_native("UmbraOS Installer", options, Box::new(move |creation| {
        let mut visuals = egui::Visuals::dark();
        visuals.panel_fill = Color32::from_rgb(7, 16, 51);
        visuals.window_fill = Color32::from_rgb(11, 23, 66);
        visuals.selection.bg_fill = Color32::from_rgb(92, 82, 165);
        creation.egui_ctx.set_visuals(visuals);
        Ok(Box::new(Installer::new(token, creation.egui_ctx.clone())))
    }))
}
