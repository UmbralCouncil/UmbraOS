use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::thread;

const REPOSITORY: &str = "/etc/umbra";
const REMOTE_URL: &str = "https://github.com/UmbralCouncil/UmbraOS.git";
const BRANCH: &str = "main";
const SOCKET: &str = "/run/umbra-update/backend.sock";
const STATUS_PATH: &str = "/var/lib/umbra-update/status.json";
const LOG_PATH: &str = "/var/log/umbra-update.log";
const GIT: &str = "@GIT@";
const NIXOS_REBUILD: &str = "@NIXOS_REBUILD@";
const HARDWARE_FILE: &str = "/etc/umbra/profile/default/hardware.nix";
const SETTINGS_FILE: &str = "/etc/umbra/installer-settings.nix";
const TRANSACTION_DIR: &str = "/var/lib/umbra-update/checkout-transaction";
const TRANSACTION_MANIFEST: &str = "/var/lib/umbra-update/checkout-transaction/manifest.json";
const HARDWARE_BACKUP: &str = "/var/lib/umbra-update/checkout-transaction/hardware.nix";
const SETTINGS_BACKUP: &str = "/var/lib/umbra-update/checkout-transaction/installer-settings.nix";

static PROXY: OnceLock<RwLock<Option<String>>> = OnceLock::new();

fn proxy_state() -> &'static RwLock<Option<String>> {
    PROXY.get_or_init(|| RwLock::new(None))
}

#[derive(Clone, Serialize, Deserialize)]
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

#[derive(Serialize, Deserialize)]
struct CheckoutTransaction {
    previous_revision: String,
    target_revision: String,
    hardware_mode: u32,
    settings_mode: u32,
}

impl Default for UpdateStatus {
    fn default() -> Self {
        Self {
            state: "idle".into(),
            build_activation_state: "not_started".into(),
            installed_revision: None,
            available_revision: None,
            previous_revision: None,
            proxy_configured: false,
            error: None,
        }
    }
}

fn log(message: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(LOG_PATH) {
        let _ = writeln!(file, "{message}");
    }
}

fn command(program: &str, args: &[&str], cwd: Option<&str>) -> Result<Output, String> {
    let mut cmd = Command::new(program);
    cmd.args(args).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(proxy) = proxy_state()
        .read()
        .map_err(|_| "proxy state is unavailable")?
        .clone()
    {
        cmd.envs([
            ("http_proxy", proxy.as_str()),
            ("https_proxy", proxy.as_str()),
            ("HTTP_PROXY", proxy.as_str()),
            ("HTTPS_PROXY", proxy.as_str()),
        ]);
    }
    if let Some(directory) = cwd {
        cmd.current_dir(directory);
    }
    log(&format!("executing {program} {}", args.join(" ")));
    cmd.output()
        .map_err(|error| format!("could not run {program}: {error}"))
}

fn checked(program: &str, args: &[&str], cwd: Option<&str>) -> Result<String, String> {
    let result = command(program, args, cwd)?;
    let stdout = String::from_utf8_lossy(&result.stdout).trim().to_owned();
    let stderr = String::from_utf8_lossy(&result.stderr).trim().to_owned();
    if !result.status.success() {
        return Err(format!(
            "{program} failed ({}): {}",
            result.status,
            if stderr.is_empty() { stdout } else { stderr }
        ));
    }
    Ok(stdout)
}

fn git(args: &[&str]) -> Result<String, String> {
    #[cfg(test)]
    let program = if GIT.starts_with('@') { "git" } else { GIT };
    #[cfg(not(test))]
    let program = GIT;
    checked(program, args, Some(REPOSITORY))
}

#[cfg(test)]
fn test_boundary(name: &str) {
    if std::env::var("UMBRA_TEST_PAUSE").ok().as_deref() == Some(name) {
        let marker = std::env::var("UMBRA_TEST_MARKER").unwrap();
        fs::write(marker, name).unwrap();
        loop {
            thread::sleep(std::time::Duration::from_secs(1));
        }
    }
}

#[cfg(not(test))]
fn test_boundary(_name: &str) {}

fn allowed_checkout_change(line: &str) -> bool {
    matches!(
        line.get(3..).unwrap_or(""),
        "profile/default/hardware.nix" | "installer-settings.nix"
    )
}

fn validate_checkout() -> Result<(), String> {
    let path = Path::new(REPOSITORY);
    let metadata =
        fs::symlink_metadata(path).map_err(|e| format!("cannot inspect {REPOSITORY}: {e}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() || metadata.uid() != 0 {
        return Err(format!(
            "{REPOSITORY} must be a root-owned directory, not a symlink"
        ));
    }
    let canonical =
        fs::canonicalize(path).map_err(|e| format!("cannot resolve {REPOSITORY}: {e}"))?;
    if canonical != path {
        return Err(format!("{REPOSITORY} resolves to an unexpected path"));
    }
    let git_dir = fs::symlink_metadata(path.join(".git"))
        .map_err(|_| format!("{REPOSITORY} is not a Git checkout"))?;
    if git_dir.file_type().is_symlink() || !git_dir.is_dir() || git_dir.uid() != 0 {
        return Err("the checkout Git directory is not safe".into());
    }
    let hardware = fs::symlink_metadata(HARDWARE_FILE)
        .map_err(|_| "hardware configuration is missing".to_string())?;
    if hardware.file_type().is_symlink() || !hardware.is_file() || hardware.uid() != 0 {
        return Err("the hardware configuration must be a root-owned regular file".into());
    }
    let settings = fs::symlink_metadata(SETTINGS_FILE)
        .map_err(|_| "installer settings are missing".to_string())?;
    if settings.file_type().is_symlink() || !settings.is_file() || settings.uid() != 0 {
        return Err("installer settings must be a root-owned regular file".into());
    }
    if git(&["remote", "get-url", "origin"])? != REMOTE_URL {
        return Err("the checkout origin does not match the UmbraOS repository".into());
    }
    if git(&["symbolic-ref", "--short", "HEAD"])? != BRANCH {
        return Err("the checkout must be on main".into());
    }
    let status = git(&["status", "--porcelain", "--untracked-files=all"])?;
    for line in status.lines() {
        if !allowed_checkout_change(line) {
            return Err(format!(
                "update blocked by unexpected checkout change: {line}"
            ));
        }
    }
    Ok(())
}

fn revision(name: &str) -> Result<String, String> {
    git(&["rev-parse", "--verify", name])
}

fn write_durable(path: &str, data: &[u8], mode: u32) -> Result<(), String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true).mode(mode);
    let mut file = options
        .open(path)
        .map_err(|e| format!("cannot create {path}: {e}"))?;
    file.write_all(data)
        .and_then(|_| file.sync_all())
        .map_err(|e| format!("cannot persist {path}: {e}"))
}

fn remove_transaction_files() -> Result<(), String> {
    for path in [TRANSACTION_MANIFEST, HARDWARE_BACKUP, SETTINGS_BACKUP] {
        match fs::remove_file(path) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(format!("cannot clean transaction file {path}: {error}")),
        }
    }
    match fs::remove_dir(TRANSACTION_DIR) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("cannot clean transaction directory: {error}")),
    }
}

fn atomic_restore(backup: &str, target: &str, mode: u32) -> Result<(), String> {
    let data =
        fs::read(backup).map_err(|e| format!("cannot read transaction backup {backup}: {e}"))?;
    let temporary = format!("{target}.umbra-update-restore");
    match fs::remove_file(&temporary) {
        Ok(()) => (),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        Err(error) => return Err(format!("cannot clear restore temporary file: {error}")),
    }
    write_durable(&temporary, &data, mode)?;
    fs::rename(&temporary, target).map_err(|e| format!("cannot atomically restore {target}: {e}"))
}

fn recover_checkout_transaction() -> Result<(), String> {
    if !Path::new(TRANSACTION_MANIFEST).exists() {
        // A crash while preparing backups occurs before Git is changed.
        return remove_transaction_files();
    }
    let transaction: CheckoutTransaction = serde_json::from_slice(
        &fs::read(TRANSACTION_MANIFEST)
            .map_err(|e| format!("cannot read update transaction: {e}"))?,
    )
    .map_err(|e| format!("update transaction is invalid: {e}"))?;
    // A kill can land before, during, or after reset. Normalize the tracked
    // tree at the journaled HEAD, then restore the local files. A third commit
    // is never guessed at under root.
    let head = git(&["rev-parse", "--verify", "HEAD"])?;
    if head != transaction.previous_revision && head != transaction.target_revision {
        return Err(format!(
            "checkout HEAD {head} is outside the pending update transaction"
        ));
    }
    git(&["reset", "--hard", &head])?;
    atomic_restore(HARDWARE_BACKUP, HARDWARE_FILE, transaction.hardware_mode)?;
    test_boundary("restore_hardware");
    atomic_restore(SETTINGS_BACKUP, SETTINGS_FILE, transaction.settings_mode)?;
    test_boundary("restore_settings");
    remove_transaction_files()?;
    log(&format!(
        "recovered machine-local files after interrupted checkout transaction {} -> {}",
        transaction.previous_revision, transaction.target_revision
    ));
    Ok(())
}

fn prepare_checkout_transaction(old: &str, new: &str) -> Result<(), String> {
    recover_checkout_transaction()?;
    fs::create_dir(TRANSACTION_DIR)
        .map_err(|e| format!("cannot create checkout transaction: {e}"))?;
    fs::set_permissions(TRANSACTION_DIR, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("cannot secure checkout transaction: {e}"))?;
    let hardware = fs::read(HARDWARE_FILE)
        .map_err(|e| format!("cannot preserve hardware configuration: {e}"))?;
    let settings =
        fs::read(SETTINGS_FILE).map_err(|e| format!("cannot preserve installer settings: {e}"))?;
    test_boundary("snapshot");
    let hardware_mode = fs::metadata(HARDWARE_FILE)
        .map_err(|e| e.to_string())?
        .mode()
        & 0o7777;
    let settings_mode = fs::metadata(SETTINGS_FILE)
        .map_err(|e| e.to_string())?
        .mode()
        & 0o7777;
    write_durable(HARDWARE_BACKUP, &hardware, 0o600)?;
    write_durable(SETTINGS_BACKUP, &settings, 0o600)?;
    let manifest = serde_json::to_vec(&CheckoutTransaction {
        previous_revision: old.into(),
        target_revision: new.into(),
        hardware_mode,
        settings_mode,
    })
    .map_err(|e| format!("cannot encode checkout transaction: {e}"))?;
    // The manifest is the commit marker: Git is never changed before it is durable.
    write_durable(TRANSACTION_MANIFEST, &manifest, 0o600)?;
    test_boundary("journal_commit");
    Ok(())
}

fn set_proxy(request: &Value, shared: &Arc<Mutex<UpdateStatus>>) -> Result<(), String> {
    let value = request
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| "proxy URL must be a string".to_string())?;
    if !value.is_empty()
        && (!(value.starts_with("http://") || value.starts_with("https://"))
            || value.len() > 2048
            || value
                .chars()
                .any(|character| character.is_control() || character.is_whitespace()))
    {
        return Err("proxy must be an http:// or https:// URL without whitespace".into());
    }
    let previous = proxy_state()
        .read()
        .map_err(|_| "proxy state is unavailable")?
        .clone();
    *proxy_state()
        .write()
        .map_err(|_| "proxy state is unavailable")? = (!value.is_empty()).then(|| value.to_owned());

    // Test only the compile-time UmbraOS endpoint. The client cannot use this
    // operation to make the root service connect to an arbitrary destination.
    if let Err(error) = checked(
        GIT,
        &["ls-remote", "--exit-code", REMOTE_URL, "refs/heads/main"],
        None,
    ) {
        *proxy_state()
            .write()
            .map_err(|_| "proxy state is unavailable")? = previous;
        return Err(format!("proxy connectivity verification failed: {error}"));
    }
    set_status(shared, |s| s.proxy_configured = !value.is_empty());
    Ok(())
}

fn persist(status: &UpdateStatus) {
    if let Ok(data) = serde_json::to_vec_pretty(status) {
        let temporary = format!("{STATUS_PATH}.tmp");
        if fs::write(&temporary, data).is_ok() {
            let _ = fs::rename(temporary, STATUS_PATH);
        }
    }
}

fn set_status(shared: &Arc<Mutex<UpdateStatus>>, change: impl FnOnce(&mut UpdateStatus)) {
    if let Ok(mut status) = shared.lock() {
        change(&mut status);
        persist(&status);
    }
}

fn fetch_status(shared: &Arc<Mutex<UpdateStatus>>) -> Result<(), String> {
    recover_checkout_transaction()?;
    validate_checkout()?;
    set_status(shared, |s| {
        s.state = "checking".into();
        s.error = None;
    });
    git(&["fetch", "--prune", "origin", BRANCH])?;
    let installed = revision("HEAD")?;
    let available = revision("origin/main")?;
    set_status(shared, |s| {
        s.state = if installed == available {
            "up_to_date"
        } else {
            "update_available"
        }
        .into();
        s.installed_revision = Some(installed);
        s.available_revision = Some(available);
    });
    Ok(())
}

fn install_update(shared: Arc<Mutex<UpdateStatus>>) -> Result<(), String> {
    recover_checkout_transaction()?;
    validate_checkout()?;
    set_status(&shared, |s| {
        s.state = "fetching".into();
        s.build_activation_state = "not_started".into();
        s.error = None;
    });
    git(&["fetch", "--prune", "origin", BRANCH])?;
    let old = revision("HEAD")?;
    let new = revision("origin/main")?;
    if old == new {
        set_status(&shared, |s| {
            s.state = "up_to_date".into();
            s.installed_revision = Some(old);
            s.available_revision = Some(new);
        });
        return Ok(());
    }
    if checked(
        GIT,
        &["merge-base", "--is-ancestor", &new, &old],
        Some(REPOSITORY),
    )
    .is_ok()
    {
        set_status(&shared, |s| {
            s.state = "up_to_date".into();
            s.installed_revision = Some(old);
            s.available_revision = Some(new);
        });
        return Ok(());
    }
    checked(
        GIT,
        &["merge-base", "--is-ancestor", &old, &new],
        Some(REPOSITORY),
    )
    .map_err(|_| "origin/main is not a fast-forward from the installed revision".to_string())?;
    prepare_checkout_transaction(&old, &new)?;
    if let Err(error) = git(&["reset", "--hard", &new]) {
        let _ = recover_checkout_transaction();
        return Err(error);
    }
    test_boundary("git_operation");
    recover_checkout_transaction()?;
    set_status(&shared, |s| {
        s.state = "building".into();
        s.build_activation_state = "running".into();
        s.previous_revision = Some(old.clone());
        s.installed_revision = Some(new.clone());
        s.available_revision = Some(new.clone());
    });
    test_boundary("rebuild");
    let result = command(
        NIXOS_REBUILD,
        &["switch", "--flake", "path:/etc/umbra#default"],
        None,
    )?;
    if !result.status.success() {
        let detail = String::from_utf8_lossy(&result.stderr).trim().to_owned();
        return Err(format!("Git updated to {new}, but Nix build/activation failed; the previous NixOS generation remains available and the prior Git revision was {old}: {detail}"));
    }
    test_boundary("activation");
    set_status(&shared, |s| {
        s.state = "complete".into();
        s.build_activation_state = "succeeded".into();
    });
    Ok(())
}

fn response(value: Value) -> Vec<u8> {
    let body = value.to_string();
    format!(
        "Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        body
    )
    .into_bytes()
}

fn handle(mut stream: UnixStream, shared: Arc<Mutex<UpdateStatus>>, update_lock: Arc<Mutex<()>>) {
    let mut raw = String::new();
    if Read::by_ref(&mut stream)
        .take(65_537)
        .read_to_string(&mut raw)
        .is_err()
        || raw.len() > 65_536
    {
        return;
    }
    let request: Value = match serde_json::from_str(&raw) {
        Ok(value) => value,
        Err(_) => {
            let _ = stream.write_all(&response(json!({"ok":false,"error":"invalid request"})));
            return;
        }
    };
    let action = request.get("action").and_then(Value::as_str).unwrap_or("");
    let result: Result<Value, String> = match action {
        "GET_UPDATE_STATUS" => Ok(serde_json::to_value(shared.lock().unwrap().clone()).unwrap()),
        "CHECK_UPDATE" => fetch_status(&shared)
            .map(|_| serde_json::to_value(shared.lock().unwrap().clone()).unwrap()),
        "SET_UPDATE_PROXY" => match update_lock.try_lock() {
            Ok(_guard) => set_proxy(&request, &shared)
                .map(|_| serde_json::to_value(shared.lock().unwrap().clone()).unwrap()),
            Err(_) => Err("cannot change proxy while an update is in progress".into()),
        },
        "INSTALL_UPDATE" => match update_lock.try_lock() {
            Ok(_guard) => install_update(Arc::clone(&shared))
                .map(|_| serde_json::to_value(shared.lock().unwrap().clone()).unwrap()),
            Err(_) => Err("an update is already in progress".into()),
        },
        _ => Err("unknown update action".into()),
    };
    if let Err(error) = &result {
        log(error);
        set_status(&shared, |s| {
            if action != "SET_UPDATE_PROXY" {
                s.state = "failed".into();
                if s.build_activation_state == "running" {
                    s.build_activation_state = "failed".into();
                }
            }
            s.error = Some(error.clone());
        });
    }
    let payload = match result {
        Ok(status) => json!({"ok":true,"status":status}),
        Err(error) => json!({"ok":false,"error":error,"status":shared.lock().unwrap().clone()}),
    };
    let _ = stream.write_all(&response(payload));
}

fn main() {
    if let Err(error) = recover_checkout_transaction() {
        log(&format!("startup recovery failed: {error}"));
        eprintln!("startup recovery failed: {error}");
        std::process::exit(1);
    }
    let _ = fs::remove_file(SOCKET);
    let listener = UnixListener::bind(SOCKET).expect("could not bind update socket");
    fs::set_permissions(SOCKET, fs::Permissions::from_mode(0o660))
        .expect("could not secure update socket");
    checked("chown", &["root:wheel", SOCKET], None).expect("could not set update socket ownership");
    let mut initial: UpdateStatus = fs::read(STATUS_PATH)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default();
    // Proxy configuration is deliberately process-local and never restored.
    initial.proxy_configured = false;
    let shared = Arc::new(Mutex::new(initial));
    let update_lock = Arc::new(Mutex::new(()));
    for stream in listener.incoming().flatten() {
        let state = Arc::clone(&shared);
        let lock = Arc::clone(&update_lock);
        thread::spawn(move || handle(stream, state, lock));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use std::process::{Child, Command as TestCommand};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_directory(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "umbra-updater-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn checkout_policy_allows_only_machine_local_files() {
        assert!(allowed_checkout_change(" M profile/default/hardware.nix"));
        assert!(allowed_checkout_change("?? installer-settings.nix"));
        assert!(!allowed_checkout_change(" M flake.nix"));
        assert!(!allowed_checkout_change("?? arbitrary-command"));
        assert!(!allowed_checkout_change(""));
    }

    #[test]
    fn atomic_restore_replaces_content_and_mode_without_following_target() {
        let directory = temporary_directory("restore");
        let backup = directory.join("backup");
        let target = directory.join("hardware.nix");
        fs::write(&backup, b"machine hardware\n").unwrap();
        let victim = directory.join("victim");
        fs::write(&victim, b"must not change\n").unwrap();
        symlink(&victim, &target).unwrap();

        atomic_restore(backup.to_str().unwrap(), target.to_str().unwrap(), 0o640).unwrap();

        assert_eq!(fs::read(&target).unwrap(), b"machine hardware\n");
        assert_eq!(fs::read(&victim).unwrap(), b"must not change\n");
        assert_eq!(fs::metadata(&target).unwrap().mode() & 0o7777, 0o640);
        fs::remove_file(backup).unwrap();
        fs::remove_file(target).unwrap();
        fs::remove_file(victim).unwrap();
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn durable_write_refuses_to_replace_an_existing_or_symlinked_file() {
        let directory = temporary_directory("durable");
        let path = directory.join("state");
        write_durable(path.to_str().unwrap(), b"first", 0o600).unwrap();
        assert!(write_durable(path.to_str().unwrap(), b"second", 0o600).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"first");
        fs::remove_file(path).unwrap();
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn interruption_worker() {
        let mode = match std::env::var("UMBRA_TEST_WORKER") {
            Ok(value) => value,
            Err(_) => return,
        };
        if mode == "recover" {
            recover_checkout_transaction().unwrap();
            return;
        }
        let old = std::env::var("UMBRA_TEST_OLD").unwrap();
        let new = std::env::var("UMBRA_TEST_NEW").unwrap();
        prepare_checkout_transaction(&old, &new).unwrap();
        git(&["reset", "--hard", &new]).unwrap();
        test_boundary("git_operation");
        recover_checkout_transaction().unwrap();
        // The real updater invokes the rebuild after the checkout journal has
        // been fully retired. These boundaries prove that killing later cannot
        // resurrect or lose machine-local checkout state.
        test_boundary("rebuild");
        test_boundary("activation");
    }

    fn namespace_worker(
        executable: &Path,
        checkout: &Path,
        state: &Path,
        mode: &str,
        stage: Option<&str>,
        marker: &Path,
        old: &str,
        new: &str,
    ) -> Child {
        let script = "mount --bind \"$1\" /etc/umbra; mount -t tmpfs tmpfs /var/lib; mkdir -p /var/lib/umbra-update; mount --bind \"$2\" /var/lib/umbra-update; exec \"$3\" --exact tests::interruption_worker --nocapture";
        let mut command = TestCommand::new("unshare");
        command
            .args(["-Urnm", "sh", "-c", script, "sh"])
            .arg(checkout)
            .arg(state)
            .arg(executable)
            .env("UMBRA_TEST_WORKER", mode)
            .env("UMBRA_TEST_MARKER", marker)
            .env("UMBRA_TEST_OLD", old)
            .env("UMBRA_TEST_NEW", new);
        if let Some(stage) = stage {
            command.env("UMBRA_TEST_PAUSE", stage);
        }
        command.spawn().unwrap()
    }

    #[test]
    fn process_interruption_recovers_every_checkout_boundary() {
        let executable = std::env::current_exe().unwrap();
        for stage in [
            "snapshot",
            "journal_commit",
            "git_operation",
            "restore_hardware",
            "restore_settings",
            "rebuild",
            "activation",
        ] {
            let fixture = temporary_directory(stage);
            let checkout = fixture.join("checkout");
            let state = fixture.join("state");
            let marker = fixture.join("paused");
            fs::create_dir(&checkout).unwrap();
            fs::create_dir(&state).unwrap();
            checked("git", &["init", "-b", "main"], checkout.to_str()).unwrap();
            checked(
                "git",
                &["config", "user.email", "test@umbra.invalid"],
                checkout.to_str(),
            )
            .unwrap();
            checked(
                "git",
                &["config", "user.name", "Umbra Test"],
                checkout.to_str(),
            )
            .unwrap();
            fs::create_dir_all(checkout.join("profile/default")).unwrap();
            fs::write(
                checkout.join("profile/default/hardware.nix"),
                "upstream old\n",
            )
            .unwrap();
            fs::write(checkout.join("tracked"), "old\n").unwrap();
            checked("git", &["add", "."], checkout.to_str()).unwrap();
            checked("git", &["commit", "-m", "old"], checkout.to_str()).unwrap();
            let old = checked("git", &["rev-parse", "HEAD"], checkout.to_str()).unwrap();
            fs::write(
                checkout.join("profile/default/hardware.nix"),
                "upstream new\n",
            )
            .unwrap();
            fs::write(checkout.join("tracked"), "new\n").unwrap();
            checked("git", &["add", "."], checkout.to_str()).unwrap();
            checked("git", &["commit", "-m", "new"], checkout.to_str()).unwrap();
            let new = checked("git", &["rev-parse", "HEAD"], checkout.to_str()).unwrap();
            checked("git", &["reset", "--hard", &old], checkout.to_str()).unwrap();
            fs::write(
                checkout.join("profile/default/hardware.nix"),
                "machine hardware\n",
            )
            .unwrap();
            fs::write(
                checkout.join("installer-settings.nix"),
                "machine settings\n",
            )
            .unwrap();

            let mut child = namespace_worker(
                &executable,
                &checkout,
                &state,
                "update",
                Some(stage),
                &marker,
                &old,
                &new,
            );
            for _ in 0..200 {
                if marker.exists() {
                    break;
                }
                thread::sleep(std::time::Duration::from_millis(10));
            }
            assert!(marker.exists(), "worker did not reach {stage}");
            child.kill().unwrap();
            let _ = child.wait();
            let mut recovery = namespace_worker(
                &executable,
                &checkout,
                &state,
                "recover",
                None,
                &marker,
                &old,
                &new,
            );
            assert!(
                recovery.wait().unwrap().success(),
                "recovery failed after {stage}"
            );
            assert_eq!(
                fs::read_to_string(checkout.join("profile/default/hardware.nix")).unwrap(),
                "machine hardware\n"
            );
            assert_eq!(
                fs::read_to_string(checkout.join("installer-settings.nix")).unwrap(),
                "machine settings\n"
            );
            assert!(!state.join("checkout-transaction").exists());
            fs::remove_dir_all(fixture).unwrap();
        }
    }
}
