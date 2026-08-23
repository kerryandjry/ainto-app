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
    /// Spotlight folders used by File Search. Empty values are ignored.
    pub file_search_paths: Vec<String>,
    /// Search the entire local Spotlight index instead of selected folders.
    pub file_search_all_locations: bool,
    /// Include hidden Spotlight results.
    pub file_search_include_hidden: bool,
    /// Items shown on the launcher home page when the query is empty.
    pub home_clipboard_history: bool,
    pub home_file_search: bool,
    pub home_snippets: bool,
    pub home_ai_commands: bool,
    /// Stable AI Command UUIDs selected for Home. None preserves legacy top-four behavior.
    pub home_ai_command_ids: Option<Vec<String>>,
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
            file_search_paths: dirs::home_dir()
                .map(|path| vec![path.to_string_lossy().into_owned()])
                .unwrap_or_default(),
            file_search_all_locations: false,
            file_search_include_hidden: false,
            home_clipboard_history: true,
            home_file_search: true,
            home_snippets: true,
            home_ai_commands: true,
            home_ai_command_ids: None,
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
        let content = annotate(toml::to_string_pretty(self)?);
        std::fs::write(path, content)?;
        Ok(())
    }

    /// Default config file path: `~/.config/ainto/config.toml`
    pub fn default_path() -> Result<PathBuf, Error> {
        config_dir().map(|d| d.join("config.toml"))
    }
}

/// Comment written above `pop_to_root_seconds`, whose meaning is not obvious
/// from the number alone — and whose two sentinel values are not discoverable
/// at all without being told.
const POP_TO_ROOT_COMMENT: &str = "\
# How long the launcher may stay on a sub-page — clipboard, snippets, AI
# commands, Claude — after being hidden. Reopening after longer than this
# returns to the search page and clears the query; reopening sooner picks up
# where you left off.
# 0 always returns to search, a negative value never does.
";

/// serde writes no comments, so add them back as the file is serialized.
///
/// Kept separate from `save`, which writes to the real config path and so
/// cannot be exercised by a test.
fn annotate(content: String) -> String {
    content.replace(
        "pop_to_root_seconds =",
        &format!("{POP_TO_ROOT_COMMENT}pop_to_root_seconds ="),
    )
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
    fn legacy_config_receives_file_search_defaults() {
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

        assert!(!config.file_search_all_locations);
        assert!(!config.file_search_include_hidden);
        assert_eq!(
            config.file_search_paths,
            Config::default().file_search_paths
        );
        assert!(config.home_clipboard_history);
        assert!(config.home_file_search);
        assert!(config.home_snippets);
        assert!(config.home_ai_commands);
        assert!(config.home_ai_command_ids.is_none());
        // Existing installs have no `pop_to_root_seconds`; they must land on the
        // default rather than on 0, which would pop back to search immediately.
        assert_eq!(config.pop_to_root_seconds, 90);
    }

    #[test]
    fn home_item_settings_round_trip() {
        let config = Config {
            home_clipboard_history: false,
            home_file_search: true,
            home_snippets: false,
            home_ai_commands: true,
            home_ai_command_ids: Some(vec!["command-one".into(), "command-two".into()]),
            ..Config::default()
        };
        let encoded = toml::to_string(&config).unwrap();
        let decoded: Config = toml::from_str(&encoded).unwrap();
        assert_eq!(decoded, config);
    }

    #[test]
    fn file_search_settings_round_trip() {
        let config = Config {
            file_search_paths: vec!["/Users/example/Documents".into()],
            file_search_all_locations: true,
            file_search_include_hidden: true,
            ..Config::default()
        };
        let encoded = toml::to_string(&config).unwrap();
        let decoded: Config = toml::from_str(&encoded).unwrap();
        assert_eq!(decoded, config);
        assert_eq!(config.pop_to_root_seconds, 90);
    }

    #[test]
    fn the_written_file_explains_pop_to_root_and_still_parses() {
        let written = annotate(toml::to_string_pretty(&Config::default()).unwrap());

        assert!(written.contains("# 0 always returns to search"));
        // The comment must sit above the key, not somewhere harmless.
        let comment = written.find("# How long the launcher").unwrap();
        let key = written.find("pop_to_root_seconds =").unwrap();
        assert!(comment < key);
        // And it must not stop the file being readable.
        assert_eq!(toml::from_str::<Config>(&written).unwrap(), Config::default());
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
