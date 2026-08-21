//! Claude Code subprocess management.
//!
//! Spawns `claude -p "<query>" --output-format stream-json` and parses streaming output.
//! Uses std::process (synchronous blocking IO) — called from a background thread on the Swift side.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::Error;

/// Cancellation state, deliberately kept out of the mutex that guards the IO.
///
/// Cancel is called from the UI thread while the reader thread is blocked in
/// `read_line`, so it must not need the IO lock (it would deadlock) and must
/// not need `&mut Child` (that would alias the reader thread's borrow). It
/// signals by pid instead.
struct Control {
    pid: i32,
    cancelled: AtomicBool,
    /// Set once the child has been reaped. After that the pid may be recycled
    /// by the OS, so it must never be signalled again.
    reaped: AtomicBool,
}

impl Control {
    fn cancel(&self) {
        if self.cancelled.swap(true, Ordering::SeqCst) {
            return; // already cancelled
        }
        if self.reaped.load(Ordering::SeqCst) {
            return; // pid no longer ours
        }
        unsafe { libc::kill(self.pid, libc::SIGKILL) };
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

/// The parts only the reader thread touches.
struct SessionIo {
    child: Child,
    reader: BufReader<std::process::ChildStdout>,
    response: String,
    session_id: Option<String>,
    streaming: bool,
}

/// A streaming Claude Code session.
///
/// Every method takes `&self`: the handle is shared between the reader thread
/// and the UI thread, with the IO behind a mutex and cancellation behind
/// atomics.
pub struct ClaudeSession {
    io: Mutex<SessionIo>,
    control: Control,
    /// Drained continuously by a dedicated thread. stderr is a pipe with a
    /// finite buffer, so leaving it unread until the stream ends would deadlock
    /// the child once it wrote more than the buffer holds.
    stderr: Arc<Mutex<String>>,
}

impl ClaudeSession {
    /// Start a new Claude session, or resume an existing one.
    pub fn start(query: &str, binary: &str, resume_session_id: Option<&str>) -> Result<Self, Error> {
        // Validate binary name: reject empty strings and dangerous characters
        if binary.is_empty() {
            return Err(Error::ClaudeSpawn("claude_binary must not be empty".into()));
        }
        if !binary
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '-' | '/' | '.' | '_'))
        {
            return Err(Error::ClaudeSpawn(format!(
                "claude_binary contains invalid characters: {binary:?}. Only alphanumeric, hyphens, slashes, dots, and underscores are allowed."
            )));
        }
        if binary.contains("..") {
            return Err(Error::ClaudeSpawn(
                "claude_binary must not contain '..' path traversal".into(),
            ));
        }

        let resolved_binary = if binary.starts_with('/') {
            binary.to_string()
        } else {
            resolve_binary_path(binary)
        };

        let path_env = std::env::var("PATH").unwrap_or_default();
        let home = std::env::var("HOME").unwrap_or_default();
        let extended_path = format!(
            "{home}/.local/bin:/usr/local/bin:/opt/homebrew/bin:{path_env}"
        );

        let mut cmd = Command::new(&resolved_binary);
        cmd.arg("-p")
            .arg(query)
            .arg("--output-format")
            .arg("stream-json")
            .arg("--verbose");

        // Resume existing session for multi-turn conversation
        if let Some(sid) = resume_session_id {
            // Validate session ID format (UUID-like: hex + hyphens)
            if !sid.chars().all(|c| c.is_ascii_hexdigit() || c == '-') || sid.is_empty() {
                return Err(Error::ClaudeSpawn(format!("invalid session ID: {sid:?}")));
            }
            cmd.arg("--resume").arg(sid);
        }

        let mut child = cmd
            .env("PATH", &extended_path)
            .env("HOME", &home)
            .current_dir(&home)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null())
            .spawn()
            .map_err(|e| Error::ClaudeSpawn(e.to_string()))?;

        let stdout = child.stdout.take().ok_or(Error::ClaudeSpawn(
            "failed to capture stdout".to_string(),
        ))?;

        let stderr = Arc::new(Mutex::new(String::new()));
        if let Some(pipe) = child.stderr.take() {
            let sink = Arc::clone(&stderr);
            std::thread::spawn(move || {
                for line in BufReader::new(pipe).lines().map_while(Result::ok) {
                    if let Ok(mut buf) = sink.lock() {
                        buf.push_str(&line);
                        buf.push('\n');
                    }
                }
            });
        }

        let pid = child.id() as i32;

        Ok(Self {
            io: Mutex::new(SessionIo {
                child,
                reader: BufReader::new(stdout),
                response: String::new(),
                session_id: None,
                streaming: true,
            }),
            control: Control {
                pid,
                cancelled: AtomicBool::new(false),
                reaped: AtomicBool::new(false),
            },
            stderr,
        })
    }

    /// Read the next text chunk from the Claude stream (blocking).
    /// Returns `None` when the stream is finished.
    pub fn next_chunk(&self) -> Option<String> {
        let mut io = self.io.lock().ok()?;
        if !io.streaming || self.control.is_cancelled() {
            io.streaming = false;
            return None;
        }

        loop {
            let mut line = String::new();
            match io.reader.read_line(&mut line) {
                Ok(0) => {
                    io.streaming = false;
                    return None;
                }
                Ok(_) => {
                    // Try to extract session_id from init event
                    if io.session_id.is_none() {
                        if let Some(sid) = extract_session_id(&line) {
                            io.session_id = Some(sid);
                        }
                    }
                    if let Some(text) = extract_text_from_stream_json(&line) {
                        io.response.push_str(&text);
                        return Some(text);
                    }
                    // Non-text event, read next line
                    continue;
                }
                Err(_) => {
                    io.streaming = false;
                    return None;
                }
            }
        }
    }

    /// Session id from the init event, once it has been seen.
    pub fn session_id(&self) -> Option<String> {
        self.io.lock().ok()?.session_id.clone()
    }

    /// Everything streamed so far.
    pub fn response(&self) -> String {
        self.io
            .lock()
            .map(|io| io.response.clone())
            .unwrap_or_default()
    }

    /// Get error info — the drained stderr plus the exit status.
    pub fn get_error(&self) -> String {
        let stderr_text = self
            .stderr
            .lock()
            .map(|buf| buf.trim_end().to_string())
            .unwrap_or_default();

        let exit_info = match self.io.lock() {
            Ok(mut io) => match io.child.try_wait() {
                Ok(Some(status)) => {
                    // try_wait reaped the child; the pid must not be signalled
                    // again because the OS is free to reuse it.
                    self.control.reaped.store(true, Ordering::SeqCst);
                    if status.success() {
                        String::new()
                    } else {
                        format!("Process exited with {status}")
                    }
                }
                Ok(None) => "Process still running".into(),
                Err(e) => format!("Could not check process: {e}"),
            },
            Err(_) => String::new(),
        };

        let mut parts = Vec::new();
        if !stderr_text.is_empty() {
            parts.push(stderr_text);
        }
        if !exit_info.is_empty() {
            parts.push(exit_info);
        }
        if parts.is_empty() {
            "Claude process ended without output. Possible rate limit or connection issue.".into()
        } else {
            parts.join("\n")
        }
    }

    /// Cancel the running session.
    ///
    /// Safe to call from another thread while `next_chunk` is blocked: it takes
    /// no lock and signals the child by pid rather than through `&mut Child`.
    pub fn cancel(&self) {
        self.control.cancel();
    }
}

impl Drop for ClaudeSession {
    fn drop(&mut self) {
        self.control.cancel();
        if let Ok(io) = self.io.get_mut() {
            let _ = io.child.wait();
        }
    }
}

/// Extract session_id from the init system event.
fn extract_session_id(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    if v.get("type")?.as_str()? == "system" {
        return v.get("session_id")?.as_str().map(|s| s.to_string());
    }
    None
}

/// Try to find the binary in common locations.
fn resolve_binary_path(name: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("{home}/.local/bin/{name}"),
        format!("/usr/local/bin/{name}"),
        format!("/opt/homebrew/bin/{name}"),
    ];
    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return path.clone();
        }
    }
    // Fallback to bare name, hope it's in PATH
    name.to_string()
}

/// Extract text content from a stream-json line.
///
/// Claude CLI stream-json format (with --verbose):
/// - `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}],...}}`
/// - `{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}`
/// - `{"type":"result","result":"...","subtype":"success",...}`
fn extract_text_from_stream_json(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;

    match v.get("type")?.as_str()? {
        // Streaming delta (if Claude uses this format)
        "content_block_delta" => {
            let delta = v.get("delta")?;
            if delta.get("type")?.as_str()? == "text_delta" {
                return delta.get("text")?.as_str().map(|s| s.to_string());
            }
            None
        }
        // Full assistant message (Claude CLI --verbose format)
        "assistant" => {
            let content = v.get("message")?.get("content")?.as_array()?;
            let text: String = content
                .iter()
                .filter_map(|b| {
                    if b.get("type")?.as_str()? == "text" {
                        b.get("text")?.as_str().map(|s| s.to_string())
                    } else {
                        None
                    }
                })
                .collect::<Vec<_>>()
                .join("");
            if text.is_empty() { None } else { Some(text) }
        }
        // Final result — skip since "assistant" already has the text
        "result" => None,
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    /// Writes a fake `claude` to a path made only of characters `start` accepts.
    fn fake_claude(body: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::path::PathBuf::from(format!(
            "/tmp/ainto-claude-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("claude");
        std::fs::write(&script, body).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        script
    }

    const CHUNK: &str =
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#;

    /// stderr is a pipe with a finite buffer. While it was only read after the
    /// stream ended, a child that wrote more than the buffer holds blocked
    /// forever — we were only draining stdout.
    #[test]
    fn large_stderr_does_not_deadlock() {
        let script = fake_claude(&format!(
            "#!/bin/sh\nawk 'BEGIN{{for(i=0;i<20000;i++) print \"stderr noise line\"}}' >&2\necho '{CHUNK}'\n"
        ));
        let path = script.to_string_lossy().into_owned();

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let session = ClaudeSession::start("q", &path, None).unwrap();
            let mut out = String::new();
            while let Some(chunk) = session.next_chunk() {
                out.push_str(&chunk);
            }
            let _ = tx.send(out);
        });

        let out = rx
            .recv_timeout(Duration::from_secs(30))
            .expect("child deadlocked writing to an undrained stderr");
        assert_eq!(out, "hi");

        std::fs::remove_dir_all(script.parent().unwrap()).ok();
    }

    /// Cancel comes from the UI thread while the reader thread is blocked in
    /// `read_line`, so it must not need the IO lock or `&mut Child`.
    #[test]
    fn cancel_unblocks_a_reader_waiting_on_a_silent_child() {
        let script = fake_claude("#!/bin/sh\nsleep 60\n");
        let path = script.to_string_lossy().into_owned();

        let session = Arc::new(ClaudeSession::start("q", &path, None).unwrap());
        let reader = Arc::clone(&session);

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            while reader.next_chunk().is_some() {}
            let _ = tx.send(());
        });

        // Let the reader get as far as blocking on the pipe.
        std::thread::sleep(Duration::from_millis(200));
        session.cancel();

        rx.recv_timeout(Duration::from_secs(10))
            .expect("cancel did not unblock the reader");

        std::fs::remove_dir_all(script.parent().unwrap()).ok();
    }
}
