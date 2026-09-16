use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

const SOCKET: &str = "/run/umbra-update/backend.sock";

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let request = match arguments.as_slice() {
        [action] if action == "check" => json!({"action":"CHECK_UPDATE"}),
        [action] if action == "install" => json!({"action":"INSTALL_UPDATE"}),
        [action] if action == "status" => json!({"action":"GET_UPDATE_STATUS"}),
        [action, url] if action == "proxy" => {
            json!({"action":"SET_UPDATE_PROXY","url":if url == "off" { "" } else { url }})
        }
        _ => {
            eprintln!("usage: umbra-update check|install|status|proxy URL|proxy off");
            std::process::exit(2);
        }
    };
    let mut stream = UnixStream::connect(SOCKET).unwrap_or_else(|e| {
        eprintln!("update service unavailable: {e}");
        std::process::exit(1)
    });
    stream.write_all(request.to_string().as_bytes()).unwrap();
    stream.shutdown(std::net::Shutdown::Write).unwrap();
    let mut reply = String::new();
    stream.read_to_string(&mut reply).unwrap();
    let body = reply
        .split_once("\r\n\r\n")
        .map(|(_, body)| body)
        .unwrap_or(&reply);
    let value: Value =
        serde_json::from_str(body).unwrap_or_else(|_| json!({"ok":false,"error":body}));
    println!("{}", serde_json::to_string_pretty(&value).unwrap());
    if value.get("ok") != Some(&Value::Bool(true)) {
        std::process::exit(1);
    }
}
