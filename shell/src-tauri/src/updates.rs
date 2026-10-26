//! The personal build deliberately has no upstream update channel. Releases are installed explicitly so an official
//! DigUp update can never replace the metadata-only video behavior.

use serde_json::Value;
use tauri::AppHandle;

#[derive(Default)]
pub struct Updates;

impl Updates {
    pub fn snapshot(&self) -> Value { Value::Null }
    pub fn menu_text(&self) -> Option<(String, bool)> { None }
}

pub fn installs_itself() -> bool { false }
pub fn start(_app: &AppHandle) {}
pub async fn check(_app: &AppHandle, _asked: bool) {}
pub fn offer(_app: &AppHandle) {}
#[allow(dead_code)]
pub async fn install(_app: &AppHandle) {}
