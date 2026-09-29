//! Cutover handoff document: the minimal live truth the Swift daemon
//! needs to adopt a running session with zero window motion.
//!
//! Unlike the session file (periodic, stale by design, no scroll
//! offsets), this is dumped fresh on demand (`paneru query handoff
//! --json`) at flip time. Unlike [`crate::state::QueryState`], it keeps
//! strip structure (columns, stacks, tabs), per-row scroll offsets, and
//! focus — everything positions derive from. Sizes, frames, titles, and
//! rules all re-probe live on the Swift side and never cross.
//!
//! Window identity is the OS window id on both sides, stable across
//! processes. Floating windows travel as ids only: they stay put
//! natively, Swift just must not tile them.

use serde::{Deserialize, Serialize};

use crate::windowset::WinID;

/// Format version. Bump on ANY field change; both sides reject mismatch.
pub const HANDOFF_VERSION: u32 = 1;

/// One workspace's rows plus the floated windows Swift must leave alone.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HandoffWorkspace {
    pub workspace_id: u64,
    /// Shown row, when the daemon marks one (mirrors the active-strip
    /// convention of [`crate::state::QueryState`] extraction).
    pub active_row: Option<u32>,
    pub rows: Vec<HandoffRow>,
    /// Floated window ids on this workspace: adopted as unmanaged.
    pub floating: Vec<WinID>,
}

/// One strip: column structure plus its scroll offset.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HandoffRow {
    pub virtual_index: u32,
    pub offset_x: i32,
    pub offset_y: i32,
    /// This row is showing (only one per workspace, if any).
    pub active: bool,
    pub columns: Vec<HandoffColumn>,
}

/// One panel, ids only (mirrors `Column`, minus the entities).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum HandoffColumn {
    Single(WinID),
    Stack(Vec<HandoffStackItem>),
    Tabs(Vec<WinID>),
    Fullscreen(WinID),
}

/// One stack item, ids only (mirrors `StackItem`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum HandoffStackItem {
    Single(WinID),
    Tabs(Vec<WinID>),
}

/// The whole flip, in one document.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HandoffDoc {
    pub v: u32,
    pub active_workspace: u64,
    pub focus: Option<WinID>,
    pub workspaces: Vec<HandoffWorkspace>,
}

impl HandoffDoc {
    /// Empty document skeleton: callers fill workspaces, then focus.
    #[must_use]
    pub fn new(active_workspace: u64) -> Self {
        Self {
            v: HANDOFF_VERSION,
            active_workspace,
            focus: None,
            workspaces: Vec::new(),
        }
    }
}
