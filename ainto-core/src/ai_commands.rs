//! Custom AI command management with TOML persistence.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct AiCommand {
    /// Stable identity, independent of `name` so a command survives a rename
    /// and two commands may share a name. Empty in files written before ids
    /// existed; `load_commands` fills those in and rewrites the file.
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub icon: Option<String>,
    pub prompt: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct AiCommandFile {
    #[serde(default)]
    pub commands: Vec<AiCommand>,
}

/// Load AI commands from a TOML file.
/// If file doesn't exist, creates it with default built-in commands.
pub fn load_commands(path: &Path) -> Result<Vec<AiCommand>, Error> {
    if !path.exists() {
        let defaults = default_commands();
        save_commands(path, &defaults)?;
        return Ok(defaults);
    }
    let content = std::fs::read_to_string(path)?;
    let file: AiCommandFile = toml::from_str(&content)?;
    let mut commands = file.commands;

    // Migrate files written before commands had ids, so an id stays stable
    // across loads rather than being regenerated every time.
    if commands.iter().any(|c| c.id.is_empty()) {
        for command in commands.iter_mut().filter(|c| c.id.is_empty()) {
            command.id = new_id();
        }
        save_commands(path, &commands)?;
    }

    Ok(commands)
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

const SYS: &str = "IMPORTANT: Output ONLY the result text. No explanations, no preamble, no comments, no markdown formatting. Just the raw transformed text.";

fn default_commands() -> Vec<AiCommand> {
    vec![
        AiCommand {
            id: new_id(),
            name: "Fix Spelling & Grammar".into(),
            icon: Some("text.badge.checkmark".into()),
            prompt: format!("{SYS}\n\nFix the spelling and grammar of the following text:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Improve Writing".into(),
            icon: Some("text.badge.star".into()),
            prompt: format!("{SYS}\n\nImprove the writing quality. Make it clearer and more professional:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Make Shorter".into(),
            icon: Some("arrow.down.right.and.arrow.up.left".into()),
            prompt: format!("{SYS}\n\nMake the following text more concise while keeping the meaning:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Make Longer".into(),
            icon: Some("arrow.up.left.and.arrow.down.right".into()),
            prompt: format!("{SYS}\n\nExpand and elaborate on the following text:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Change Tone to Professional".into(),
            icon: Some("briefcase".into()),
            prompt: format!("{SYS}\n\nRewrite the following text in a professional tone:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Change Tone to Casual".into(),
            icon: Some("face.smiling".into()),
            prompt: format!("{SYS}\n\nRewrite the following text in a casual, friendly tone:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Translate to English".into(),
            icon: Some("globe".into()),
            prompt: format!("{SYS}\n\nTranslate the following text to English:\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Translate to Traditional Chinese".into(),
            icon: Some("globe.asia.australia".into()),
            prompt: format!("{SYS}\n\nTranslate the following text to Traditional Chinese (繁體中文):\n\n{{selection}}"),
        },
        AiCommand {
            id: new_id(),
            name: "Explain This".into(),
            icon: Some("questionmark.circle".into()),
            prompt: "Explain the following text or code in simple terms:\n\n{selection}".into(),
        },
        AiCommand {
            id: new_id(),
            name: "Summarize".into(),
            icon: Some("doc.plaintext".into()),
            prompt: "Summarize the following text concisely:\n\n{selection}".into(),
        },
    ]
}

/// Save AI commands to a TOML file.
pub fn save_commands(path: &Path, commands: &[AiCommand]) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = AiCommandFile {
        commands: commands.to_vec(),
    };
    let content = toml::to_string_pretty(&file)?;
    std::fs::write(path, content)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("ainto-aicmd-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("ai-commands.toml")
    }

    #[test]
    fn ids_are_assigned_once_and_stay_stable() {
        let path = temp_path();
        // A file from before ids existed.
        std::fs::write(
            &path,
            r#"
[[commands]]
name = "Translate"
prompt = "translate {selection}"

[[commands]]
name = "Translate"
prompt = "a second command that happens to share a name"
"#,
        )
        .unwrap();

        let first = load_commands(&path).unwrap();
        assert_eq!(first.len(), 2);
        assert!(first.iter().all(|c| !c.id.is_empty()), "ids get filled in");
        assert_ne!(first[0].id, first[1].id, "same name, different identity");

        // The migration is written back, so a reload keeps the same ids.
        let second = load_commands(&path).unwrap();
        assert_eq!(
            first.iter().map(|c| &c.id).collect::<Vec<_>>(),
            second.iter().map(|c| &c.id).collect::<Vec<_>>(),
        );

        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn renaming_preserves_identity() {
        let path = temp_path();
        let mut commands = load_commands(&path).unwrap(); // seeds defaults
        let id = commands[0].id.clone();
        commands[0].name = "Renamed".into();
        save_commands(&path, &commands).unwrap();

        let reloaded = load_commands(&path).unwrap();
        assert_eq!(reloaded[0].id, id);
        assert_eq!(reloaded[0].name, "Renamed");

        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }
}
