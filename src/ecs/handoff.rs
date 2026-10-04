//! Cutover handoff extraction: strip structure, scroll offsets, focus, and
//! floated windows as plain OS ids for the Swift daemon to adopt.
//!
//! The pure builder ([`build_handoff_doc`]) resolves entity views into the
//! wire document so the contract test pins it without a world;
//! [`HandoffParams`] gathers the views in one system parameter for the
//! query handler. Column handling mirrors `extract_window_set`: floated
//! members leave their column for the workspace floating list, emptied
//! columns drop, and stale entities resolve to nothing and vanish.
//!
//! Windows in no strip at all are skipped: Swift adopts unknown windows
//! natively (floating stays floating), so nothing observable moves.

use std::collections::HashMap;

use bevy::ecs::entity::Entity;
use bevy::ecs::query::{Has, With};
use bevy::ecs::system::{Query, SystemParam};
use paneru_shared_types::handoff::{HandoffColumn, HandoffDoc, HandoffStackItem, HandoffWorkspace};

use super::layout::{Column, LayoutStrip, StackItem};
use super::params::Windows;
use super::{ActiveWorkspaceMarker, Position, Unmanaged};
use crate::manager::Window;
use crate::platform::{WinID, WorkspaceId};

/// One column with entities still attached.
pub enum HandoffColumnView {
    Single(Entity),
    Stack(Vec<HandoffStackView>),
    Tabs(Vec<Entity>),
    Fullscreen(Entity),
}

/// One stack item with entities still attached.
pub enum HandoffStackView {
    Single(Entity),
    Tabs(Vec<Entity>),
}

/// One strip with entities still attached.
pub struct HandoffStripView {
    pub workspace_id: WorkspaceId,
    pub virtual_index: u32,
    pub active: bool,
    pub offset_x: i32,
    pub offset_y: i32,
    pub columns: Vec<HandoffColumnView>,
    /// Floated members of this strip (adopted as unmanaged).
    pub floating: Vec<Entity>,
}

/// Resolves strip structure into the wire document. `id_of` maps entities
/// to OS window ids (`None` drops the member as stale); `is_floating`
/// routes members to the workspace floating list instead of columns.
pub fn build_handoff_doc(
    strips: Vec<HandoffStripView>,
    focus: Option<WinID>,
    id_of: impl Fn(Entity) -> Option<WinID>,
    is_floating: impl Fn(Entity) -> bool,
) -> HandoffDoc {
    // Group rows by workspace in first-seen order.
    let mut order: Vec<WorkspaceId> = Vec::new();
    let mut rows: HashMap<WorkspaceId, Vec<HandoffStripView>> = HashMap::new();
    for strip in strips {
        if !order.contains(&strip.workspace_id) {
            order.push(strip.workspace_id);
        }
        rows.entry(strip.workspace_id).or_default().push(strip);
    }

    let mut workspaces = Vec::new();
    for workspace_id in &order {
        let mut handoff_rows = Vec::new();
        let mut floating = Vec::new();
        let mut active_row = None;
        let mut strip_rows = rows.remove(workspace_id).unwrap_or_default();
        strip_rows.sort_by_key(|row| row.virtual_index);
        for row in strip_rows {
            if row.active && active_row.is_none() {
                active_row = Some(row.virtual_index);
            }
            for entity in &row.floating {
                if let Some(id) = id_of(*entity) {
                    floating.push(id);
                }
            }
            let mut columns = Vec::new();
            for column in row.columns {
                if let Some(column) = resolve_column(column, &id_of, &is_floating, &mut floating) {
                    columns.push(column);
                }
            }
            handoff_rows.push(paneru_shared_types::handoff::HandoffRow {
                virtual_index: row.virtual_index,
                offset_x: row.offset_x,
                offset_y: row.offset_y,
                active: row.active,
                columns,
            });
        }
        workspaces.push(HandoffWorkspace {
            workspace_id: *workspace_id,
            active_row,
            rows: handoff_rows,
            floating,
        });
    }

    // The focused window's workspace owns activity; otherwise the first
    // workspace with a shown row; otherwise the first workspace at all.
    let focus_workspace = focus.and_then(|id| {
        workspaces.iter().find_map(|workspace| {
            workspace
                .rows
                .iter()
                .flat_map(|row| {
                    row.columns.iter().flat_map(|column| match column {
                        HandoffColumn::Single(id) | HandoffColumn::Fullscreen(id) => vec![*id],
                        HandoffColumn::Tabs(ids) => ids.clone(),
                        HandoffColumn::Stack(items) => items
                            .iter()
                            .flat_map(|item| match item {
                                HandoffStackItem::Single(id) => vec![*id],
                                HandoffStackItem::Tabs(ids) => ids.clone(),
                            })
                            .collect(),
                    })
                })
                .any(|member| member == id)
                .then_some(workspace.workspace_id)
        })
    });
    let active_workspace = focus_workspace
        .or_else(|| {
            workspaces.iter().find_map(|workspace| {
                workspace
                    .rows
                    .iter()
                    .any(|row| row.active)
                    .then_some(workspace.workspace_id)
            })
        })
        .or_else(|| workspaces.first().map(|workspace| workspace.workspace_id))
        .unwrap_or_default();

    let mut doc = HandoffDoc::new(active_workspace);
    doc.focus = focus;
    doc.workspaces = workspaces;
    doc
}

/// Resolves one column view, routing floated members out (see
/// [`resolve_member`]). Empty results drop the column.
fn resolve_column(
    column: HandoffColumnView,
    id_of: impl Fn(Entity) -> Option<WinID>,
    is_floating: impl Fn(Entity) -> bool,
    floating: &mut Vec<WinID>,
) -> Option<HandoffColumn> {
    match column {
        HandoffColumnView::Single(entity) => {
            resolve_member(entity, &id_of, &is_floating, floating).map(HandoffColumn::Single)
        }
        HandoffColumnView::Fullscreen(entity) => {
            resolve_member(entity, &id_of, &is_floating, floating).map(HandoffColumn::Fullscreen)
        }
        HandoffColumnView::Tabs(entities) => {
            let mut ids = Vec::new();
            for entity in entities {
                if let Some(id) = resolve_member(entity, &id_of, &is_floating, floating) {
                    ids.push(id);
                }
            }
            (!ids.is_empty()).then_some(HandoffColumn::Tabs(ids))
        }
        HandoffColumnView::Stack(items) => {
            let mut resolved_items = Vec::new();
            for item in items {
                match item {
                    HandoffStackView::Single(entity) => {
                        if let Some(id) = resolve_member(entity, &id_of, &is_floating, floating) {
                            resolved_items.push(HandoffStackItem::Single(id));
                        }
                    }
                    HandoffStackView::Tabs(entities) => {
                        let mut ids = Vec::new();
                        for entity in entities {
                            if let Some(id) = resolve_member(entity, &id_of, &is_floating, floating)
                            {
                                ids.push(id);
                            }
                        }
                        if !ids.is_empty() {
                            resolved_items.push(HandoffStackItem::Tabs(ids));
                        }
                    }
                }
            }
            (!resolved_items.is_empty()).then_some(HandoffColumn::Stack(resolved_items))
        }
    }
}

/// Resolves one member: stale entities vanish (`None`); floated members
/// join the workspace floating list and leave their column (`None`).
fn resolve_member(
    entity: Entity,
    id_of: impl Fn(Entity) -> Option<WinID>,
    is_floating: impl Fn(Entity) -> bool,
    floating: &mut Vec<WinID>,
) -> Option<WinID> {
    let id = id_of(entity)?;
    if is_floating(entity) {
        floating.push(id);
        return None;
    }
    Some(id)
}

/// The world access handoff extraction needs, bundled so the query
/// handler takes one parameter. Mirrors the strip half of
/// [`QueryStateParams`](super::state::QueryStateParams).
#[derive(SystemParam)]
pub struct HandoffParams<'w, 's> {
    strips: Query<
        'w,
        's,
        (
            &'static LayoutStrip,
            &'static Position,
            Has<ActiveWorkspaceMarker>,
        ),
    >,
    unmanaged: Query<'w, 's, (Entity, Option<&'static Unmanaged>), With<Window>>,
    windows: Windows<'w, 's>,
}

impl HandoffParams<'_, '_> {
    /// Builds the handoff document from the current world.
    pub fn extract_handoff(&self) -> HandoffDoc {
        let floating: HashMap<Entity, bool> = self
            .unmanaged
            .iter()
            .map(|(entity, unmanaged)| (entity, matches!(unmanaged, Some(Unmanaged::Floating))))
            .collect();
        let strips = self
            .strips
            .iter()
            .map(|(strip, position, active)| HandoffStripView {
                workspace_id: strip.id(),
                virtual_index: strip.virtual_index,
                offset_x: position.0.x,
                offset_y: position.0.y,
                active,
                columns: strip
                    .columns()
                    .map(|column| match column {
                        Column::Single(entity) => HandoffColumnView::Single(*entity),
                        Column::Fullscren(entity) => HandoffColumnView::Fullscreen(*entity),
                        Column::Tabs(entities) => HandoffColumnView::Tabs(entities.clone()),
                        Column::Stack(items) => HandoffColumnView::Stack(
                            items
                                .iter()
                                .map(|item| match item {
                                    StackItem::Single(entity) => HandoffStackView::Single(*entity),
                                    StackItem::Tabs(entities) => {
                                        HandoffStackView::Tabs(entities.clone())
                                    }
                                })
                                .collect(),
                        ),
                    })
                    .collect(),
                floating: strip
                    .columns()
                    .flat_map(|column| column.window_iter())
                    .filter(|entity| floating.get(entity).copied().unwrap_or(false))
                    .collect(),
            })
            .collect();
        let focus = self.windows.focused().map(|(window, _)| window.id());
        build_handoff_doc(
            strips,
            focus,
            |entity| self.windows.get(entity).map(|window| window.id()),
            |entity| floating.get(&entity).copied().unwrap_or(false),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::ecs::world::World;
    use paneru_shared_types::handoff::{
        HANDOFF_VERSION, HandoffColumn, HandoffDoc, HandoffStackItem,
    };

    /// The wire contract, pinned without a world: structure, offsets,
    /// floating routing, focus ownership, and JSON stability.
    #[test]
    fn build_handoff_doc_pins_the_contract() {
        let mut world = World::new();
        let entities: Vec<Entity> = (0..6).map(|_| world.spawn_empty().id()).collect();
        let id_of = |entity: Entity| {
            entities
                .iter()
                .position(|candidate| *candidate == entity)
                .map(|index| WinID::try_from(index).expect("test ids fit"))
        };
        let is_floating = |entity: Entity| entity == entities[4];

        let strips = vec![
            HandoffStripView {
                workspace_id: 2,
                virtual_index: 0,
                active: true,
                offset_x: -88,
                offset_y: 20,
                columns: vec![
                    HandoffColumnView::Single(entities[0]),
                    HandoffColumnView::Stack(vec![
                        HandoffStackView::Single(entities[1]),
                        HandoffStackView::Tabs(vec![entities[2], entities[5]]),
                    ]),
                    HandoffColumnView::Tabs(vec![entities[4]]),
                ],
                floating: vec![],
            },
            HandoffStripView {
                workspace_id: 2,
                virtual_index: 1,
                active: false,
                offset_x: 0,
                offset_y: 20,
                columns: vec![HandoffColumnView::Single(entities[3])],
                floating: vec![],
            },
        ];
        let doc = build_handoff_doc(strips, Some(1), id_of, is_floating);

        assert_eq!(doc.v, HANDOFF_VERSION);
        assert_eq!(doc.active_workspace, 2);
        assert_eq!(doc.focus, Some(1));
        assert_eq!(doc.workspaces.len(), 1);
        let workspace = &doc.workspaces[0];
        assert_eq!(workspace.workspace_id, 2);
        assert_eq!(workspace.active_row, Some(0));
        // The floated tab-group member leaves its stack for floating.
        assert_eq!(workspace.floating, vec![4]);
        assert_eq!(workspace.rows.len(), 2);
        assert_eq!(
            workspace.rows[0].columns,
            vec![
                HandoffColumn::Single(0),
                HandoffColumn::Stack(vec![
                    HandoffStackItem::Single(1),
                    HandoffStackItem::Tabs(vec![2, 5]),
                ]),
            ]
        );
        assert_eq!(
            (workspace.rows[0].offset_x, workspace.rows[0].offset_y),
            (-88, 20)
        );
        assert_eq!(
            workspace.rows[1].columns,
            vec![HandoffColumn::Single(3)],
            "inactive rows keep their columns"
        );
        // Stale entities vanish without disturbing the rest.
        let stale = build_handoff_doc(
            vec![HandoffStripView {
                workspace_id: 9,
                virtual_index: 0,
                active: false,
                offset_x: 0,
                offset_y: 0,
                columns: vec![HandoffColumnView::Single(entities[0])],
                floating: vec![],
            }],
            None,
            |_| None,
            |_| false,
        );
        assert_eq!(stale.workspaces[0].rows[0].columns.len(), 0);
        assert_eq!(stale.focus, None);
        assert_eq!(stale.active_workspace, 9);
        // JSON stability: the flip reads this across processes.
        let line = serde_json::to_string(&doc).expect("serializes");
        let back: HandoffDoc = serde_json::from_str(&line).expect("parses");
        assert_eq!(&back, &doc);
    }
}
