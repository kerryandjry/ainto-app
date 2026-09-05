//! Global launcher aliases with TOML persistence.

use std::collections::HashSet;
use std::path::Path;

use serde::{Deserialize, Serialize};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;

use crate::Error;

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct AliasEntry {
    #[serde(default)]
    pub alias: String,
    #[serde(default)]
    pub hotkey_key_code: Option<u32>,
    #[serde(default)]
    pub hotkey_modifiers: Option<u32>,
    #[serde(default)]
    pub hotkey_display: Option<String>,
    pub target_type: String,
    pub target_id: String,
}

#[derive(Deserialize, Serialize, Debug, Clone, Default)]
struct AliasFile {
    #[serde(default)]
    aliases: Vec<AliasEntry>,
}

/// Normalize aliases for exact, Unicode-aware, case-insensitive matching.
pub fn normalize_alias(value: &str) -> String {
    value.trim().nfkc().case_fold().nfkc().collect()
}

pub fn validate_aliases(aliases: &[AliasEntry]) -> Result<(), String> {
    let mut seen_aliases = HashSet::new();
    let mut seen_hotkeys = HashSet::new();
    for entry in aliases {
        // Preserve retired targets on disk without reserving aliases or shortcuts.
        if entry.target_type == "snippet" {
            continue;
        }
        let normalized = normalize_alias(&entry.alias);
        let hotkey = entry
            .hotkey_key_code
            .zip(entry.hotkey_modifiers)
            .zip(entry.hotkey_display.as_deref());
        if normalized.is_empty() && hotkey.is_none() {
            return Err("An alias or shortcut is required".into());
        }
        let valid_target_type = matches!(
            entry.target_type.as_str(),
            "app" | "ai_command" | "snippet" | "launcher_command" | "system_action"
        );
        if !valid_target_type || entry.target_id.trim().is_empty() {
            return Err(format!("Alias '{}' has an invalid target", entry.alias));
        }
        if !normalized.is_empty() && !seen_aliases.insert(normalized) {
            return Err(format!("Alias '{}' is already in use", entry.alias.trim()));
        }
        if let Some(((key_code, modifiers), display)) = hotkey {
            if modifiers == 0 || display.trim().is_empty() {
                return Err("Shortcut must include a modifier key".into());
            }
            if !seen_hotkeys.insert((key_code, modifiers)) {
                return Err(format!("Shortcut '{display}' is already in use"));
            }
        } else if entry.hotkey_key_code.is_some()
            || entry.hotkey_modifiers.is_some()
            || entry.hotkey_display.is_some()
        {
            return Err("Shortcut configuration is incomplete".into());
        }
    }
    Ok(())
}

pub fn load_aliases(path: &Path) -> Result<Vec<AliasEntry>, Error> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = std::fs::read_to_string(path)?;
    let file: AliasFile = toml::from_str(&content)?;
    validate_aliases(&file.aliases).map_err(Error::InvalidAliases)?;
    Ok(file.aliases)
}

pub fn save_aliases(path: &Path, aliases: &[AliasEntry]) -> Result<(), String> {
    validate_aliases(aliases)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let content = toml::to_string_pretty(&AliasFile {
        aliases: aliases.to_vec(),
    })
    .map_err(|e| e.to_string())?;
    let temporary = path.with_extension("toml.tmp");
    std::fs::write(&temporary, content).map_err(|e| e.to_string())?;
    std::fs::rename(&temporary, path).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(alias: &str) -> AliasEntry {
        AliasEntry {
            alias: alias.into(),
            hotkey_key_code: None,
            hotkey_modifiers: None,
            hotkey_display: None,
            target_type: "system_action".into(),
            target_id: "sleep".into(),
        }
    }

    #[test]
    fn retired_snippet_aliases_round_trip_without_reserving_bindings() {
        let path = std::env::temp_dir().join(format!("ainto-retired-{}.toml", uuid::Uuid::new_v4()));
        let mut retired = entry("files");
        retired.target_type = "snippet".into();
        retired.hotkey_key_code = Some(8);
        retired.hotkey_modifiers = Some(2048);
        retired.hotkey_display = Some("Option C".into());
        let mut active = retired.clone();
        active.target_type = "system_action".into();
        save_aliases(&path, &[retired, active]).unwrap();
        let loaded = load_aliases(&path).unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].target_type, "snippet");
        assert_eq!(loaded[0].hotkey_key_code, Some(8));
        assert!(validate_aliases(&loaded).is_ok());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn normalization_is_trimmed_and_case_insensitive() {
        assert_eq!(normalize_alias("  TC  "), "tc");
    }

    #[test]
    fn duplicate_aliases_are_rejected_case_insensitively() {
        let error = validate_aliases(&[entry("tc"), entry(" TC ")]).unwrap_err();
        assert!(error.contains("already in use"));
    }

    #[test]
    fn duplicate_aliases_are_rejected_with_full_unicode_case_folding() {
        let error = validate_aliases(&[entry("straße"), entry("STRASSE")]).unwrap_err();
        assert!(error.contains("already in use"));
    }

    #[test]
    fn duplicate_aliases_are_rejected_across_unicode_normalization_forms() {
        let error = validate_aliases(&[entry("café"), entry("cafe\u{301}")]).unwrap_err();
        assert!(error.contains("already in use"));
    }

    #[test]
    fn empty_alias_is_rejected_without_a_hotkey() {
        assert!(validate_aliases(&[entry("  ")]).is_err());
    }

    #[test]
    fn legacy_entry_without_hotkey_fields_still_loads() {
        let file: AliasFile = toml::from_str(
            r#"
[[aliases]]
alias = "files"
target_type = "launcher_command"
target_id = "file-search"
"#,
        )
        .unwrap();
        assert_eq!(file.aliases.len(), 1);
        assert!(file.aliases[0].hotkey_key_code.is_none());
    }

    #[test]
    fn hotkey_only_entry_is_valid() {
        let mut value = entry("");
        value.hotkey_key_code = Some(8);
        value.hotkey_modifiers = Some(2048);
        value.hotkey_display = Some("⌥ C".into());
        assert!(validate_aliases(&[value]).is_ok());
    }

    #[test]
    fn hotkey_only_entry_round_trips_through_toml() {
        let path =
            std::env::temp_dir().join(format!("ainto-alias-hotkey-{}.toml", uuid::Uuid::new_v4()));
        let mut value = entry("");
        value.hotkey_key_code = Some(8);
        value.hotkey_modifiers = Some(2048);
        value.hotkey_display = Some("⌥ C".into());
        save_aliases(&path, &[entry("files"), value]).unwrap();
        let loaded = load_aliases(&path).unwrap();
        assert!(loaded[0].hotkey_key_code.is_none());
        assert_eq!(loaded[1].hotkey_key_code, Some(8));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn duplicate_hotkeys_are_rejected() {
        let mut first = entry("clipboard");
        first.hotkey_key_code = Some(8);
        first.hotkey_modifiers = Some(2048);
        first.hotkey_display = Some("⌥ C".into());
        let mut second = entry("files");
        second.hotkey_key_code = Some(8);
        second.hotkey_modifiers = Some(2048);
        second.hotkey_display = Some("⌥ C".into());
        assert!(validate_aliases(&[first, second]).is_err());
    }
}
