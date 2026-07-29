use std::env;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

const RUNTIME_PATH: &str = "@PATH@";
const NIX_BIN: &str = "@NIX@";
const UMBRA_SOURCE: &str = "@UMBRA_SOURCE@";
const NIXPKGS_SOURCE: &str = "@NIXPKGS_SOURCE@";
const NIXPKGS_UNSTABLE_SOURCE: &str = "@NIXPKGS_UNSTABLE_SOURCE@";
const HOME_MANAGER_SOURCE: &str = "@HOME_MANAGER_SOURCE@";
const MICROVM_SOURCE: &str = "@MICROVM_SOURCE@";
const SPECTRUM_SOURCE: &str = "@SPECTRUM_SOURCE@";
const LOG_PATH: &str = "/tmp/umbra-installer.log";
const BACKEND_SOCKET: &str = "/run/umbra-installer/backend.sock";
const BACKEND_PID: &str = "/run/umbra-installer/backend.pid";

#[derive(Debug)]
struct BackendError {
    client: bool,
    message: String,
}

type BackendResult<T> = Result<T, BackendError>;

impl BackendError {
    fn client(message: impl Into<String>) -> Self {
        Self {
            client: true,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            client: false,
            message: message.into(),
        }
    }
}

struct MountGuard {
    active: bool,
}

impl MountGuard {
    fn new() -> Self {
        Self { active: true }
    }

    fn cleanup(&mut self) {
        if self.active {
            let _ = Command::new("umount").args(["-R", "/mnt"]).status();
            self.active = false;
        }
    }
}

impl Drop for MountGuard {
    fn drop(&mut self) {
        self.cleanup();
    }
}

fn log(message: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(LOG_PATH) {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_secs())
            .unwrap_or_default();
        let _ = writeln!(file, "[{timestamp}] {message}");
    }
}

fn cgi_response(status: Option<&str>, content_type: &str, body: &str) -> String {
    let mut response = String::new();
    if let Some(status) = status {
        response.push_str("Status: ");
        response.push_str(status);
        response.push_str("\r\n");
    }
    response.push_str("Content-Type: ");
    response.push_str(content_type);
    response.push_str("\r\nCache-Control: no-store\r\n\r\n");
    response.push_str(body);
    if !body.ends_with('\n') {
        response.push('\n');
    }
    response
}

fn output(program: &str, args: &[&str]) -> BackendResult<String> {
    let result = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| BackendError::internal(format!("could not run {program}: {error}")))?;
    let stdout = String::from_utf8_lossy(&result.stdout).trim().to_owned();
    let stderr = String::from_utf8_lossy(&result.stderr).trim().to_owned();
    if !stderr.is_empty() {
        log(&format!("{program}: {stderr}"));
    }
    if !result.status.success() {
        return Err(BackendError::internal(format!(
            "{program} exited with {}{}",
            result.status,
            if stderr.is_empty() {
                String::new()
            } else {
                format!(": {stderr}")
            }
        )));
    }
    Ok(stdout)
}

fn status_description(status: std::process::ExitStatus) -> String {
    if let Some(code) = status.code() {
        format!("exit code {code}")
    } else if let Some(signal) = status.signal() {
        format!("signal {signal}")
    } else {
        status.to_string()
    }
}

fn diagnostic_tail(text: &str, limit: usize) -> String {
    let characters: Vec<char> = text.chars().collect();
    characters[characters.len().saturating_sub(limit)..]
        .iter()
        .collect()
}

fn stream_pipe<R>(reader: R, label: &'static str) -> thread::JoinHandle<Vec<u8>>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        let mut captured = Vec::new();
        loop {
            let mut chunk = Vec::new();
            match reader.read_until(b'\n', &mut chunk) {
                Ok(0) => break,
                Ok(_) => {
                    captured.extend_from_slice(&chunk);
                    let line = String::from_utf8_lossy(&chunk)
                        .trim_end_matches(['\r', '\n'])
                        .to_owned();
                    if !line.is_empty() {
                        log(&format!("[nix {label}] {line}"));
                    }
                }
                Err(error) => {
                    log(&format!("[nix {label}] stream read failed: {error}"));
                    break;
                }
            }
        }
        captured
    })
}

fn streamed_output(program: &str, args: &[&str]) -> BackendResult<String> {
    log(&format!("executing: {program} {}", args.join(" ")));
    let started = SystemTime::now();
    let mut child = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            BackendError::internal(format!(
                "could not start {program}: {error}; PATH={RUNTIME_PATH}"
            ))
        })?;
    log(&format!("spawned {program} as PID {}", child.id()));
    let stdout_thread = stream_pipe(
        child
            .stdout
            .take()
            .ok_or_else(|| BackendError::internal("nix stdout pipe was unavailable"))?,
        "stdout",
    );
    let stderr_thread = stream_pipe(
        child
            .stderr
            .take()
            .ok_or_else(|| BackendError::internal("nix stderr pipe was unavailable"))?,
        "stderr",
    );
    let status = child
        .wait()
        .map_err(|error| BackendError::internal(format!("could not wait for {program}: {error}")))?;
    let stdout = stdout_thread
        .join()
        .map_err(|_| BackendError::internal("nix stdout logger panicked"))?;
    let stderr = stderr_thread
        .join()
        .map_err(|_| BackendError::internal("nix stderr logger panicked"))?;
    let elapsed = started
        .elapsed()
        .map(|duration| duration.as_secs())
        .unwrap_or_default();
    let status_text = status_description(status);
    log(&format!("{program} finished with {status_text} after {elapsed}s"));
    let stdout = String::from_utf8_lossy(&stdout).trim().to_owned();
    let stderr = String::from_utf8_lossy(&stderr).trim().to_owned();
    if !status.success() {
        let details = if stderr.is_empty() {
            diagnostic_tail(&stdout, 12_000)
        } else {
            diagnostic_tail(&stderr, 12_000)
        };
        return Err(BackendError::internal(format!(
            "target system build failed with {status_text} after {elapsed}s\n\n{details}\n\nFull log: {LOG_PATH}"
        )));
    }
    Ok(stdout)
}

fn run(program: &str, args: &[&str]) -> BackendResult<()> {
    log(&format!("running {program} {}", args.join(" ")));
    output(program, args).map(|_| ())
}

fn jq(input: &str, filter: &str) -> BackendResult<String> {
    let mut child = Command::new("jq")
        .args(["-er", filter])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| BackendError::internal(format!("could not run jq: {error}")))?;
    child
        .stdin
        .take()
        .ok_or_else(|| BackendError::internal("jq stdin was unavailable"))?
        .write_all(input.as_bytes())
        .map_err(|error| BackendError::internal(format!("could not write to jq: {error}")))?;
    let result = child
        .wait_with_output()
        .map_err(|error| BackendError::internal(format!("could not read jq output: {error}")))?;
    if !result.status.success() {
        return Err(BackendError::client(format!(
            "invalid installer request: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&result.stdout).trim().to_owned())
}

fn device_type(device: &str) -> BackendResult<String> {
    output("lsblk", &["-dnro", "TYPE", "--", device])
}

fn root_disk(device: &str) -> BackendResult<String> {
    let names = output("lsblk", &["-s", "-nrpo", "NAME", "--", device])?;
    names
        .lines()
        .last()
        .map(str::to_owned)
        .ok_or_else(|| BackendError::client(format!("could not resolve parent disk for {device}")))
}

fn live_disk() -> String {
    let source = output("findmnt", &["-nro", "SOURCE", "/iso"]).unwrap_or_default();
    if source.is_empty() {
        String::new()
    } else {
        root_disk(&source).unwrap_or_default()
    }
}

fn reject_live_device(device: &str) -> BackendResult<()> {
    let candidate = root_disk(device)?;
    let live = live_disk();
    if !live.is_empty() && candidate == live {
        return Err(BackendError::client(format!(
            "refusing to modify the disk backing the live UmbraOS session ({live})"
        )));
    }
    Ok(())
}

fn unmount_device(device: &str) -> BackendResult<()> {
    let targets = output("findmnt", &["-rn", "-S", device, "-o", "TARGET"]).unwrap_or_default();
    let mut targets: Vec<&str> = targets.lines().filter(|target| !target.is_empty()).collect();
    targets.sort_by_key(|target| std::cmp::Reverse(target.len()));
    for target in targets {
        if target == "/"
            || target == "/iso"
            || target == "/nix"
            || target.starts_with("/nix/")
            || target == "/run/current-system"
        {
            return Err(BackendError::client(format!(
                "refusing to unmount critical live filesystem {target}"
            )));
        }
        log(&format!("unmounting {device} from {target}"));
        run("umount", &["--", target]).map_err(|_| {
            BackendError::client(format!(
                "could not unmount {device} from {target}; close any open files and retry"
            ))
        })?;
    }
    Ok(())
}

fn unmount_disk_tree(disk: &str) -> BackendResult<()> {
    let devices = output("lsblk", &["-lnpo", "NAME", "--", disk])?;
    for device in devices.lines().rev() {
        unmount_device(device)?;
    }
    Ok(())
}

fn validate_username(value: &str) -> bool {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) if first.is_ascii_lowercase() || first == '_' => {}
        _ => return false,
    }
    value.len() <= 31
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '_'
                || character == '-'
        })
}

fn validate_hostname(value: &str) -> bool {
    value.len() <= 63
        && value
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_alphanumeric())
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '.' || character == '-'
        })
}

fn validate_timezone(value: &str) -> bool {
    value.contains('/')
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || matches!(character, '_' | '+' | '-' | '/')
        })
        && Path::new("/etc/zoneinfo").join(value).exists()
}

fn hash_password(password: &str) -> BackendResult<String> {
    let mut child = Command::new("mkpasswd")
        .args(["-m", "yescrypt", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| BackendError::internal(format!("could not start mkpasswd: {error}")))?;
    child
        .stdin
        .take()
        .ok_or_else(|| BackendError::internal("mkpasswd stdin was unavailable"))?
        .write_all(password.as_bytes())
        .map_err(|error| BackendError::internal(format!("could not hash password: {error}")))?;
    let result = child
        .wait_with_output()
        .map_err(|error| BackendError::internal(format!("could not read password hash: {error}")))?;
    if !result.status.success() {
        return Err(BackendError::internal(format!(
            "mkpasswd failed: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&result.stdout).trim().to_owned())
}

fn disks_response() -> BackendResult<String> {
    let devices = output(
        "lsblk",
        &[
            "-J",
            "-b",
            "-o",
            "NAME,PATH,TYPE,SIZE,MODEL,FSTYPE,LABEL,PARTTYPE,MOUNTPOINTS",
        ],
    )?;
    let live = live_disk();
    let mut child = Command::new("jq")
        .args(["--arg", "live_disk", &live, ". + {umbra_live_disk: $live_disk}"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| BackendError::internal(format!("could not start jq: {error}")))?;
    child
        .stdin
        .take()
        .ok_or_else(|| BackendError::internal("jq stdin was unavailable"))?
        .write_all(devices.as_bytes())
        .map_err(|error| BackendError::internal(format!("could not send lsblk JSON: {error}")))?;
    let result = child
        .wait_with_output()
        .map_err(|error| BackendError::internal(format!("could not read disk JSON: {error}")))?;
    if !result.status.success() {
        return Err(BackendError::internal(format!(
            "could not compose disk JSON: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    Ok(cgi_response(
        None,
        "application/json",
        &String::from_utf8_lossy(&result.stdout),
    ))
}

fn log_response() -> BackendResult<String> {
    let contents = fs::read_to_string(LOG_PATH).unwrap_or_default();
    Ok(cgi_response(
        None,
        "text/plain; charset=utf-8",
        &diagnostic_tail(&contents, 60_000),
    ))
}

fn build_target_system() -> BackendResult<String> {
    let nixpkgs = format!("path:{NIXPKGS_SOURCE}");
    let nixpkgs_unstable = format!("path:{NIXPKGS_UNSTABLE_SOURCE}");
    let home_manager = format!("path:{HOME_MANAGER_SOURCE}");
    let microvm = format!("path:{MICROVM_SOURCE}");
    let spectrum = format!("path:{SPECTRUM_SOURCE}");
    let args = [
        "--extra-experimental-features",
        "nix-command flakes",
        "build",
        "--show-trace",
        "--print-build-logs",
        "--verbose",
        "--no-link",
        "--print-out-paths",
        "--no-write-lock-file",
        "--override-input",
        "nixpkgs",
        &nixpkgs,
        "--override-input",
        "nixpkgs-unstable",
        &nixpkgs_unstable,
        "--override-input",
        "home-manager",
        &home_manager,
        "--override-input",
        "microvm",
        &microvm,
        "--override-input",
        "microvm/spectrum",
        &spectrum,
        "path:/mnt/etc/umbra#nixosConfigurations.default.config.system.build.toplevel",
    ];
    streamed_output(NIX_BIN, &args)
}

fn install_system(body: &str) -> BackendResult<String> {
    let mode = jq(body, ".mode // empty")?;
    let username = jq(body, ".username // empty")?;
    let hostname = jq(body, ".hostname // empty")?;
    let timezone = jq(body, ".timezone // empty")?;
    let password = jq(body, ".password // empty")?;
    let confirmation = jq(body, ".confirmation // empty")?;

    // Each installation gets a fresh diagnostic transcript. Without this, the
    // UI can surface a stale failure from an earlier attempt while the current
    // backend is operating normally.
    let _ = fs::write(LOG_PATH, "");
    log("========== installation request started ==========");
    log(&format!(
        "request settings: mode={mode} username={username} hostname={hostname} timezone={timezone}"
    ));

    if !validate_username(&username) {
        return Err(BackendError::client("invalid username"));
    }
    if !validate_hostname(&hostname) {
        return Err(BackendError::client("invalid hostname"));
    }
    if !validate_timezone(&timezone) {
        return Err(BackendError::client("invalid or unknown time zone"));
    }
    if password.len() < 8 {
        return Err(BackendError::client("password is too short"));
    }
    if !Path::new("/sys/firmware/efi").is_dir() {
        return Err(BackendError::client(
            "Umbra Installer currently requires UEFI boot",
        ));
    }

    let (root, esp) = if mode == "erase" {
        let disk = jq(body, ".disk // empty")?;
        if device_type(&disk)? != "disk" {
            return Err(BackendError::client("target is not a disk"));
        }
        reject_live_device(&disk)?;
        if confirmation != format!("ERASE {disk}") {
            return Err(BackendError::client("confirmation mismatch"));
        }
        unmount_disk_tree(&disk)?;
        run("wipefs", &["--all", "--force", &disk])?;
        run("parted", &["-s", &disk, "mklabel", "gpt"])?;
        run(
            "parted",
            &["-s", &disk, "mkpart", "ESP", "fat32", "1MiB", "1025MiB"],
        )?;
        run("parted", &["-s", &disk, "set", "1", "esp", "on"])?;
        run(
            "parted",
            &["-s", &disk, "mkpart", "UmbraOS", "btrfs", "1025MiB", "100%"],
        )?;
        run("partprobe", &[&disk])?;
        run("udevadm", &["settle"])?;
        let separator = if disk.contains("nvme") || disk.contains("mmcblk") {
            "p"
        } else {
            ""
        };
        let esp = format!("{disk}{separator}1");
        let root = format!("{disk}{separator}2");
        run("mkfs.fat", &["-F", "32", "-n", "UMBRA_EFI", &esp])?;
        (root, esp)
    } else if mode == "manual" {
        let root = jq(body, ".root // empty")?;
        let esp = jq(body, ".esp // empty")?;
        if device_type(&root)? != "part" {
            return Err(BackendError::client("root target is not a partition"));
        }
        if device_type(&esp)? != "part" {
            return Err(BackendError::client("EFI target is not a partition"));
        }
        reject_live_device(&root)?;
        reject_live_device(&esp)?;
        if root == esp {
            return Err(BackendError::client(
                "root and EFI partitions must differ",
            ));
        }
        if confirmation != format!("FORMAT {root}") {
            return Err(BackendError::client("confirmation mismatch"));
        }
        if output("lsblk", &["-dnro", "FSTYPE", "--", &esp])? != "vfat" {
            return Err(BackendError::client(
                "EFI System Partition must be FAT32",
            ));
        }
        unmount_device(&root)?;
        unmount_device(&esp)?;
        (root, esp)
    } else {
        return Err(BackendError::client("invalid installation mode"));
    };

    run("mkfs.btrfs", &["-f", "-L", "UMBRA_ROOT", &root])?;
    run("mount", &[&root, "/mnt"])?;
    let mut mounts = MountGuard::new();
    fs::create_dir_all("/mnt/boot")
        .and_then(|_| fs::create_dir_all("/mnt/etc"))
        .map_err(|error| BackendError::internal(format!("could not prepare /mnt: {error}")))?;
    run("mount", &[&esp, "/mnt/boot"])?;
    run("cp", &["-r", UMBRA_SOURCE, "/mnt/etc/umbra"])?;
    run("chmod", &["-R", "u+w", "/mnt/etc/umbra"])?;
    run("nixos-generate-config", &["--root", "/mnt"])?;
    run(
        "cp",
        &[
            "/mnt/etc/nixos/hardware-configuration.nix",
            "/mnt/etc/umbra/profile/default/hardware.nix",
        ],
    )?;

    let password_hash = hash_password(&password)?;
    let settings = format!(
        "{{\n  timeZone = \"{timezone}\";\n  hostName = \"{hostname}\";\n  account = {{\n    name = \"{username}\";\n    hashedPassword = \"{password_hash}\";\n  }};\n}}\n"
    );
    fs::write("/mnt/etc/umbra/installer-settings.nix", settings)
        .map_err(|error| BackendError::internal(format!("could not write settings: {error}")))?;

    log("building target system from ISO-pinned flake inputs");
    let system_path = build_target_system()?;
    if system_path.is_empty() {
        return Err(BackendError::internal(
            "target build returned no system path",
        ));
    }
    run(
        "nixos-install",
        &[
            "--no-root-passwd",
            "--root",
            "/mnt",
            "--system",
            &system_path,
        ],
    )?;
    run("sync", &[])?;
    mounts.cleanup();

    Ok(cgi_response(
        None,
        "application/json",
        "{\"ok\":true,\"message\":\"UmbraOS was installed successfully. You may reboot.\"}",
    ))
}

fn handle_request(raw: &str, expected_token: &str, install_lock: &Mutex<()>) -> String {
    let result = (|| -> BackendResult<String> {
        let token = jq(raw, ".token // empty")?;
        if token != expected_token {
            return Err(BackendError::client("invalid installer token"));
        }
        let action = jq(raw, ".action // empty")?;
        let method = jq(raw, ".method // \"GET\"")?;
        let body = jq(raw, ".body // {} | @json")?;
        match action.as_str() {
            "disks" => disks_response(),
            "log" => log_response(),
            "install" => {
                if method != "POST" {
                    return Err(BackendError::client("POST required"));
                }
                let _guard = install_lock.try_lock().map_err(|_| {
                    BackendError::client("an installation is already in progress")
                })?;
                install_system(&body)
            }
            _ => Err(BackendError::client("unknown action")),
        }
    })();

    match result {
        Ok(response) => response,
        Err(error) => {
            log(&format!("request failed: {}", error.message));
            let status = if error.client {
                "400 Bad Request"
            } else {
                "500 Internal Server Error"
            };
            cgi_response(Some(status), "text/plain", &error.message)
        }
    }
}

fn handle_connection(
    mut stream: UnixStream,
    token: Arc<String>,
    install_lock: Arc<Mutex<()>>,
) {
    let mut request = String::new();
    if let Err(error) = Read::by_ref(&mut stream)
        .take(1_048_577)
        .read_to_string(&mut request)
    {
        log(&format!("could not read RPC request: {error}"));
        return;
    }
    if request.len() > 1_048_576 {
        let response = cgi_response(
            Some("413 Payload Too Large"),
            "text/plain",
            "installer request exceeded 1 MiB",
        );
        let _ = stream.write_all(response.as_bytes());
        return;
    }
    let response = handle_request(&request, &token, &install_lock);
    let _ = stream.write_all(response.as_bytes());
}

fn serve(socket: &str, token: String) -> BackendResult<()> {
    if socket != BACKEND_SOCKET {
        return Err(BackendError::client(format!(
            "backend socket must be {BACKEND_SOCKET}"
        )));
    }
    if token.len() != 48
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(BackendError::client(
            "backend token must be 48 lowercase hexadecimal characters",
        ));
    }

    let socket_path = Path::new(socket);
    let parent = socket_path
        .parent()
        .ok_or_else(|| BackendError::internal("socket has no parent directory"))?;
    fs::create_dir_all(parent)
        .map_err(|error| BackendError::internal(format!("could not create socket dir: {error}")))?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o750))
        .map_err(|error| BackendError::internal(format!("could not secure socket dir: {error}")))?;
    let parent_text = parent
        .to_str()
        .ok_or_else(|| BackendError::internal("socket directory is not valid UTF-8"))?;
    run("chown", &["root:users", parent_text])?;
    if socket_path.exists() {
        fs::remove_file(socket_path)
            .map_err(|error| BackendError::internal(format!("could not replace socket: {error}")))?;
    }
    let listener = UnixListener::bind(socket_path)
        .map_err(|error| BackendError::internal(format!("could not bind socket: {error}")))?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|error| BackendError::internal(format!("could not secure socket: {error}")))?;
    run("chown", &["nixos:users", socket])?;
    fs::write(BACKEND_PID, std::process::id().to_string())
        .map_err(|error| BackendError::internal(format!("could not write backend PID: {error}")))?;
    fs::set_permissions(BACKEND_PID, fs::Permissions::from_mode(0o644))
        .map_err(|error| BackendError::internal(format!("could not secure backend PID: {error}")))?;
    log(&format!("Rust backend listening on {socket}"));

    let token = Arc::new(token);
    let install_lock = Arc::new(Mutex::new(()));
    for connection in listener.incoming() {
        match connection {
            Ok(stream) => {
                let token = Arc::clone(&token);
                let install_lock = Arc::clone(&install_lock);
                thread::spawn(move || handle_connection(stream, token, install_lock));
            }
            Err(error) => log(&format!("socket accept failed: {error}")),
        }
    }
    Ok(())
}

fn stop() -> BackendResult<()> {
    let pid_text = fs::read_to_string(BACKEND_PID)
        .map_err(|error| BackendError::internal(format!("could not read backend PID: {error}")))?;
    let pid = pid_text
        .trim()
        .parse::<u32>()
        .map_err(|_| BackendError::internal("backend PID file is invalid"))?;
    let running_exe = fs::canonicalize(format!("/proc/{pid}/exe"))
        .map_err(|error| BackendError::internal(format!("could not inspect backend process: {error}")))?;
    let this_exe = fs::canonicalize(
        env::current_exe()
            .map_err(|error| BackendError::internal(format!("could not identify backend: {error}")))?,
    )
    .map_err(|error| BackendError::internal(format!("could not resolve backend path: {error}")))?;
    if running_exe != this_exe {
        return Err(BackendError::client(
            "refusing to stop a process that is not the Umbra installer backend",
        ));
    }
    let status = Command::new("kill")
        .arg(pid.to_string())
        .status()
        .map_err(|error| BackendError::internal(format!("could not stop backend: {error}")))?;
    if !status.success() {
        return Err(BackendError::internal("backend stop command failed"));
    }
    for _ in 0..50 {
        if !Path::new(&format!("/proc/{pid}")).exists() {
            break;
        }
        thread::sleep(std::time::Duration::from_millis(20));
    }
    let _ = fs::remove_file(BACKEND_SOCKET);
    let _ = fs::remove_file(BACKEND_PID);
    Ok(())
}

fn main() {
    env::set_var("PATH", RUNTIME_PATH);
    let arguments: Vec<String> = env::args().collect();
    let result = match arguments.as_slice() {
        [_, mode, socket, token] if mode == "serve" => serve(socket, token.clone()),
        [_, mode] if mode == "stop" => stop(),
        _ => Err(BackendError::client(
            "usage: umbra-installer-backend serve SOCKET TOKEN | stop",
        )),
    };
    if let Err(error) = result {
        log(&error.message);
        eprintln!("{}", error.message);
        std::process::exit(1);
    }
}
