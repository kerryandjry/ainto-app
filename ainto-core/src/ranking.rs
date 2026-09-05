//! Frecency-based ranking: frequency + recency.
//!
//! Each entry stores a count and last_used timestamp.
//! Score = count * 10 * decay, where decay decreases over days since last use.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RankingEntry {
    pub count: i32,
    pub last_used: i64, // unix timestamp
    /// Whether this app should appear on the launcher home page.
    #[serde(default)]
    pub pinned: bool,
}

impl Default for RankingEntry {
    fn default() -> Self {
        Self::new()
    }
}

impl RankingEntry {
    /// A first use: one hit, right now.
    pub fn new() -> Self {
        Self {
            count: 1,
            last_used: now(),
            pinned: false,
        }
    }

    /// Increment usage count and update last_used.
    pub fn increment(&mut self) {
        self.count += 1;
        self.last_used = now();
    }

    /// Calculate frecency score.
    /// Decays over time: full score within 1 day, drops to 0 after 20 days.
    pub fn frecency_score(&self) -> i32 {
        let days_since = (now() - self.last_used) as f64 / 86400.0;
        let decay = (1.0 - days_since * 0.05).clamp(0.0, 1.0);
        let raw = (self.count as f64 * 10.0 * decay) as i32;
        raw.min(100) // cap at 100
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RankingFile {
    #[serde(default)]
    pub rankings: HashMap<String, RankingEntry>,
}

/// Load rankings from a TOML file.
pub fn load_rankings(path: &Path) -> HashMap<String, RankingEntry> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|content| {
            // Try new format first
            if let Ok(value) = toml::from_str::<toml::Value>(&content)
                && value.get("rankings").is_some_and(toml::Value::is_table)
            {
                return toml::from_str::<RankingFile>(&content)
                    .ok()
                    .map(|file| file.rankings);
            }
            // Migrate from old format: key = i32
            if let Ok(old) = toml::from_str::<HashMap<String, i32>>(&content) {
                let migrated: HashMap<String, RankingEntry> = old
                    .into_iter()
                    .map(|(k, v)| {
                        (
                            k,
                            RankingEntry {
                                count: v,
                                last_used: now(),
                                pinned: false,
                            },
                        )
                    })
                    .collect();
                // Write back in new format
                let _ = save_rankings(path, &migrated);
                return Some(migrated);
            }
            None
        })
        .unwrap_or_default()
}

/// Save rankings to a TOML file.
pub fn save_rankings(path: &Path, rankings: &HashMap<String, RankingEntry>) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = RankingFile {
        rankings: rankings.clone(),
    };
    let content = toml::to_string_pretty(&file)?;
    std::fs::write(path, content)?;
    Ok(())
}

/// Process-wide cache of the ranking table.
///
/// `get_score` is on the search-scoring path and is called once per candidate
/// while ranking results, so re-reading and re-parsing the TOML on every call
/// cost a file read per lookup. The file is only ever written through
/// `increment_and_save`, so the cache stays authoritative for this process.
///
/// Production uses one ranking path, while path-aware storage keeps tests and
/// callers with temporary config roots isolated from one another.
static CACHE: Mutex<Option<(PathBuf, HashMap<String, RankingEntry>)>> = Mutex::new(None);

/// Run `f` against the cached ranking table, loading it when the path changes.
fn with_cache<T>(path: &Path, f: impl FnOnce(&mut HashMap<String, RankingEntry>) -> T) -> T {
    let mut guard = CACHE.lock().unwrap_or_else(|error| error.into_inner());
    let cache = guard.get_or_insert_with(|| (path.to_path_buf(), load_rankings(path)));
    if cache.0 != path {
        *cache = (path.to_path_buf(), load_rankings(path));
    }
    f(&mut cache.1)
}

/// Snapshot of the current ranking table.
pub fn all_rankings(path: &Path) -> HashMap<String, RankingEntry> {
    with_cache(path, |rankings| rankings.clone())
}

/// Clear usage rankings while preserving explicit Home pins.
pub fn reset(path: &Path) -> Result<(), Error> {
    with_cache(path, |rankings| {
        let mut reset_rankings = rankings.clone();
        reset_rankings.retain(|_, entry| {
            if entry.pinned {
                entry.count = 0;
                entry.last_used = now();
                true
            } else {
                false
            }
        });

        if reset_rankings.is_empty() {
            match std::fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        } else {
            save_rankings(path, &reset_rankings)?;
        }
        *rankings = reset_rankings;
        Ok(())
    })
}

/// Increment a key and save. Returns the new frecency score.
pub fn increment_and_save(path: &Path, key: &str) -> i32 {
    with_cache(path, |rankings| {
        let entry = rankings
            .entry(key.to_string())
            .and_modify(|e| e.increment())
            .or_default();
        let score = entry.frecency_score();
        let _ = save_rankings(path, rankings);
        score
    })
}

/// Get frecency score for a key.
pub fn get_score(path: &Path, key: &str) -> i32 {
    with_cache(path, |rankings| {
        rankings.get(key).map(|e| e.frecency_score()).unwrap_or(0)
    })
}

/// Persist an app's home-page pin without changing its usage ranking.
pub fn set_pinned(path: &Path, key: &str, pinned: bool) -> Result<(), Error> {
    with_cache(path, |rankings| update_pin(path, rankings, key, pinned))
}

fn update_pin(
    path: &Path,
    rankings: &mut HashMap<String, RankingEntry>,
    key: &str,
    pinned: bool,
) -> Result<(), Error> {
    let mut updated = rankings.clone();
    updated
        .entry(key.to_string())
        .and_modify(|entry| entry.pinned = pinned)
        .or_insert_with(|| RankingEntry {
            count: 0,
            last_used: now(),
            pinned,
        });
    save_rankings(path, &updated)?;
    *rankings = updated;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_counts_survive_migration() {
        let path = std::env::temp_dir().join(format!("ainto-legacy-{}.toml", uuid::Uuid::new_v4()));
        std::fs::write(
            &path,
            "\"/Applications/A.app\" = 3\n\"/Applications/B.app\" = 7\n",
        )
        .unwrap();
        for _ in 0..2 {
            let loaded = load_rankings(&path);
            assert_eq!(loaded.len(), 2);
            assert_eq!(loaded["/Applications/A.app"].count, 3);
            assert_eq!(loaded["/Applications/B.app"].count, 7);
        }
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn failed_pin_save_does_not_change_cache() {
        let path = std::env::temp_dir().join(format!("ainto-pin-fail-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        for originally_pinned in [false, true] {
            let mut rankings = HashMap::from([(
                "app".into(),
                RankingEntry {
                    count: 3,
                    last_used: 123,
                    pinned: originally_pinned,
                },
            )]);
            assert!(update_pin(&path, &mut rankings, "app", !originally_pinned).is_err());
            assert_eq!(rankings["app"].pinned, originally_pinned);
            assert_eq!(rankings["app"].count, 3);
        }
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn reset_clears_the_cache_and_removes_the_file() {
        let directory = std::env::temp_dir().join(format!(
            "ainto-ranking-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let path = directory.join("ranking.toml");

        assert!(increment_and_save(&path, "app:test") > 0);
        assert!(path.exists());

        reset(&path).unwrap();

        assert_eq!(get_score(&path, "app:test"), 0);
        assert!(!path.exists());
        std::fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn structured_entries_without_pinned_remain_unpinned() {
        let file: RankingFile = toml::from_str(
            r#"
[rankings."/Applications/Test.app"]
count = 3
last_used = 123
"#,
        )
        .unwrap();
        assert!(!file.rankings["/Applications/Test.app"].pinned);
    }

    #[test]
    fn pinned_state_does_not_increase_usage() {
        let path =
            std::env::temp_dir().join(format!("ainto-ranking-pin-{}.toml", uuid::Uuid::new_v4()));
        set_pinned(&path, "/Applications/Test.app", true).unwrap();
        let entry = load_rankings(&path)
            .remove("/Applications/Test.app")
            .unwrap();
        assert!(entry.pinned);
        assert_eq!(entry.count, 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn reset_preserves_pins_while_clearing_usage() {
        let path =
            std::env::temp_dir().join(format!("ainto-ranking-reset-{}.toml", uuid::Uuid::new_v4()));
        let app = "/Applications/Test.app";

        set_pinned(&path, app, true).unwrap();
        assert!(increment_and_save(&path, app) > 0);
        reset(&path).unwrap();

        let entry = load_rankings(&path).remove(app).unwrap();
        assert!(entry.pinned);
        assert_eq!(entry.count, 0);
        assert_eq!(get_score(&path, app), 0);
        let _ = std::fs::remove_file(path);
    }
}
