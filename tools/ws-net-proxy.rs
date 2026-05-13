//! WebSocket-to-TAP proxy for ESP-EMU browser networking.
//!
//! Bridges Ethernet frames between a WebSocket client (browser) and a Linux TAP
//! interface. Build with: `cargo build --release --features ws-proxy --bin ws-net-proxy`
//!
//! Usage:
//!     sudo ./tools/setup-tap.sh
//!     ./target/release/ws-net-proxy [--tap tap0] [--port 8765]

use std::io;
use std::net::{TcpListener, TcpStream};
use std::os::unix::io::RawFd;
use std::thread;

use tungstenite::protocol::Message;
use tungstenite::accept;

const TAP_MTU: usize = 1600;

// Linux TAP constants
const TUNSETIFF: libc::c_ulong = 0x400454CA;
const IFF_TAP: libc::c_short = 0x0002;
const IFF_NO_PI: libc::c_short = 0x1000;

fn open_tap(name: &str) -> io::Result<RawFd> {
    unsafe {
        let fd = libc::open(b"/dev/net/tun\0".as_ptr() as *const _, libc::O_RDWR);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        let mut ifr = [0u8; 40]; // struct ifreq
        let name_bytes = name.as_bytes();
        let copy_len = name_bytes.len().min(15);
        ifr[..copy_len].copy_from_slice(&name_bytes[..copy_len]);
        let flags = (IFF_TAP | IFF_NO_PI) as u16;
        ifr[16..18].copy_from_slice(&flags.to_le_bytes());

        if libc::ioctl(fd, TUNSETIFF, ifr.as_ptr()) < 0 {
            libc::close(fd);
            return Err(io::Error::last_os_error());
        }

        Ok(fd)
    }
}

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}

fn poll_fd(fd: RawFd, timeout_ms: i32) -> bool {
    unsafe {
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        libc::poll(&mut pfd, 1, timeout_ms) > 0 && (pfd.revents & libc::POLLIN) != 0
    }
}

fn handle_client(stream: TcpStream, tap_fd: RawFd) {
    let peer = stream.peer_addr().ok();
    eprintln!(
        "[ws-net-proxy] Client connected: {}",
        peer.map_or("unknown".to_string(), |a| a.to_string())
    );

    stream
        .set_nonblocking(false)
        .expect("set_nonblocking failed");

    let mut ws = match accept(stream) {
        Ok(ws) => ws,
        Err(e) => {
            eprintln!("[ws-net-proxy] WebSocket handshake failed: {}", e);
            return;
        }
    };

    // Set the underlying TCP stream to nonblocking for interleaved TAP/WS polling
    ws.get_ref()
        .set_nonblocking(true)
        .expect("set_nonblocking failed");
    set_nonblocking(tap_fd);

    let mut tap_buf = [0u8; TAP_MTU];

    loop {
        // Poll TAP for incoming frames → send to WebSocket
        if poll_fd(tap_fd, 1) {
            loop {
                let n = unsafe {
                    libc::read(tap_fd, tap_buf.as_mut_ptr() as *mut _, tap_buf.len())
                };
                if n <= 0 {
                    break;
                }
                let frame = &tap_buf[..n as usize];
                if ws.send(Message::Binary(frame.to_vec().into())).is_err() {
                    break;
                }
            }
        }

        // Poll WebSocket for incoming frames → write to TAP
        match ws.read() {
            Ok(Message::Binary(data)) => {
                if data.len() >= 14 {
                    unsafe {
                        libc::write(tap_fd, data.as_ptr() as *const _, data.len());
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {} // Ignore text/ping/pong
            Err(tungstenite::Error::Io(ref e))
                if e.kind() == io::ErrorKind::WouldBlock =>
            {
                // No data available — this is normal for nonblocking
            }
            Err(_) => break,
        }
    }

    let _ = ws.close(None);
    eprintln!("[ws-net-proxy] Client disconnected");
}

fn main() {
    let mut tap_name = "tap0".to_string();
    let mut port: u16 = 8765;
    let mut host = "0.0.0.0".to_string();

    // Simple arg parsing
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--tap" | "-t" => {
                i += 1;
                if i >= args.len() { eprintln!("--tap requires a value"); std::process::exit(1); }
                tap_name = args[i].clone();
            }
            "--port" | "-p" => {
                i += 1;
                if i >= args.len() { eprintln!("--port requires a value"); std::process::exit(1); }
                port = args[i].parse().expect("invalid port");
            }
            "--host" => {
                i += 1;
                if i >= args.len() { eprintln!("--host requires a value"); std::process::exit(1); }
                host = args[i].clone();
            }
            "-h" | "--help" => {
                eprintln!("Usage: ws-net-proxy [--tap NAME] [--port PORT] [--host ADDR]");
                eprintln!("  --tap NAME   TAP interface (default: tap0)");
                eprintln!("  --port PORT  WebSocket port (default: 8765)");
                eprintln!("  --host ADDR  Bind address (default: 0.0.0.0)");
                std::process::exit(0);
            }
            _ => {
                eprintln!("Unknown arg: {}", args[i]);
                std::process::exit(1);
            }
        }
        i += 1;
    }

    let tap_fd = match open_tap(&tap_name) {
        Ok(fd) => fd,
        Err(e) => {
            eprintln!(
                "Error: cannot open TAP '{}': {}. Run setup-tap.sh first.",
                tap_name, e
            );
            std::process::exit(1);
        }
    };
    eprintln!("[ws-net-proxy] TAP '{}' opened (fd={})", tap_name, tap_fd);

    let bind_addr = format!("{}:{}", host, port);
    let listener = TcpListener::bind(&bind_addr).unwrap_or_else(|e| {
        eprintln!("Error: cannot bind to {}: {}", bind_addr, e);
        std::process::exit(1);
    });

    eprintln!("[ws-net-proxy] Listening on ws://{}", bind_addr);
    eprintln!(
        "[ws-net-proxy] Enter ws://localhost:{} in the browser Network field",
        port
    );

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let tap = tap_fd;
                thread::spawn(move || handle_client(stream, tap));
            }
            Err(e) => eprintln!("[ws-net-proxy] Accept error: {}", e),
        }
    }
}
