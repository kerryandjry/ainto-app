//! Configuration management.
//!
//! Reads/writes TOML config at `~/.config/ainto/config.toml`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Config {
    pub clipboard_max_items: usize,
    pub clipboard_max_image_items: usize,
    pub claude_binary: String,
    pub snippets_enabled: bool,
    /// Master switch for all AI-related features in the UI.
    /// When false, the launcher hides every AI surface.
    pub ai_enabled: bool,
    /// Seconds the launcher may stay on a sub-page while hidden before the next
    /// invocation returns to the search page. `0` returns immediately; a
    /// negative value stays on the sub-page indefinitely.
    pub pop_to_root_seconds: i64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            clipboard_max_items: 200,
            clipboard_max_image_items: 50,
            claude_binary: "claude".to_string(),
            snippets_enabled: true,
            ai_enabled: true,
            pop_to_root_seconds: 90,
        }
    }
}

impl Config {
    /// Load config from the default path, creating with defaults if missing.
    pub fn load() -> Result<Self, Error> {
        let path = Self::default_path()?;
        if path.exists() {
            let content = std::fs::read_to_string(&path)?;
            let config: Config = toml::from_str(&content)?;
            Ok(config)
        } else {
            let config = Config::default();
            config.save()?;
            Ok(config)
        }
    }

    /// Save config to the default path.
    pub fn save(&self) -> Result<(), Error> {
        let path = Self::default_path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    /// Default config file path: `~/.config/ainto/config.toml`
    pub fn default_path() -> Result<PathBuf, Error> {
        config_dir().map(|d| d.join("config.toml"))
    }
}

/// Returns the ainto config directory: `~/.config/ainto/`
pub fn config_dir() -> Result<PathBuf, Error> {
    let home = dirs::home_dir().ok_or(Error::NoHomeDir)?;
    Ok(home.join(".config").join("ainto"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_without_the_key_gets_the_default_delay() {
        // Existing installs have no `pop_to_root_seconds`; they must land on the
        // default rather than on 0, which would pop back to search immediately.
        let config: Config = toml::from_str(
            r#"
clipboard_max_items = 100
clipboard_max_image_items = 25
claude_binary = "claude"
snippets_enabled = true
ai_enabled = true
"#,
        )
        .unwrap();

        assert_eq!(config.pop_to_root_seconds, 90);
    }

    #[test]
    fn pop_to_root_settings_round_trip() {
        // 0 and negative values are the "immediately" and "never" choices, so
        // they must survive a save/load cycle as written rather than being
        // normalised into the default.
        for seconds in [0, 45, 90, -1] {
            let config = Config {
                pop_to_root_seconds: seconds,
                ..Config::default()
            };
            let decoded: Config = toml::from_str(&toml::to_string(&config).unwrap()).unwrap();
            assert_eq!(decoded.pop_to_root_seconds, seconds);
        }
    }
}
