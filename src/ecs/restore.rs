use std::collections::{HashMap, HashSet};
use std::time::Duration;

use bevy::ecs::entity::Entity;
use bevy::ecs::observer::On;
use bevy::ecs::query::Has;
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{Commands, Query, Res, ResMut};
use bevy::time::{Time, Timer, TimerMode, Virtual};
use objc2_core_graphics::CGDirectDisplayID;
use tracing::{Level, info, instrument, warn};

use crate::config::{Config, MissingWindowBehavior};
use crate::ecs::layout::{LayoutStrip, PARKED_STRIP_SLIVER, clamp_size_to_viewport};
use crate::ecs::params::{WindowCtx, Windows};
use crate::ecs::state::{
    PaneruState, SavedColumn, SavedStackItem, SavedStrip, SavedWindow, SavedWorkspace,
};
use crate::ecs::workspace::PreviousStripPosition;
use crate::ecs::{
    ActiveDisplayMarker, ActiveWorkspaceMarker, DockPosition, RestoreWindowState, SpawnCommandsExt,
    Unmanaged,
};
use crate::manager::{Application, Display, Window};
use crate::platform::{Pid, WinID, WorkspaceId};

#[derive(Debug, Resource)]
pub(crate) struct SessionRestore {
    state: PaneruState,
    timer: Timer,
    saved_hard_keys: HashSet<WindowHardMatchKey>,
}

impl SessionRestore {
    fn new(state: PaneruState, grace: Duration) -> Self {
        let saved_hard_keys = saved_hard_match_keys(&state);
        Self {
            state,
            timer: Timer::new(grace, TimerMode::Once),
            saved_hard_keys,
        }
    }
}

pub(super) fn tick_restore_grace(
    time: Res<Time<Virtual>>,
    mut session: Option<ResMut<SessionRestore>>,
    apps: Query<&Application>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(session) = session.as_mut() else {
        return;
    };

    session.timer.tick(time.delta());
    if session.timer.is_finished() {
        info!("Session restore grace period ended");
        if config.restore_missing_windows() == MissingWindowBehavior::Drop {
            // Drop saved windows whose app never opened: without this the
            // stale entries (with their cached displays) sit in the file
            // until the next save and can resurrect across a crash before
            // it. Late launches inside the grace already matched above.
            let launched: HashSet<String> = apps.iter().filter_map(|app| app.bundle_id()).collect();
            let removed = session.state.prune_unlaunched(&launched);
            if removed > 0 {
                info!("Session restore dropping {removed} window(s) from unlaunched apps");
                if let Err(err) = session
                    .state
                    .save_to_file(&PaneruState::default_state_file_path())
                {
                    warn!("Session restore failed to rewrite state file: {err}");
                }
            }
        }
        commands.remove_resource::<SessionRestore>();
        commands.remove_resource::<PaneruState>();
    }
}

#[derive(Clone, Debug)]
pub(crate) struct CurrentWindowIdentity {
    pub entity: Entity,
    pub window_id: WinID,
    pub pid: Pid,
    pub bundle_id: String,
    pub title: String,
    pub identifier: String,
    pub role: String,
    pub subrole: String,
}

impl CurrentWindowIdentity {
    fn hard_key(&self) -> WindowHardMatchKey {
        WindowHardMatchKey::new(self.window_id, self.pid, self.bundle_id.clone())
    }

    #[cfg(test)]
    pub(crate) fn fallback_only(entity: Entity, bundle_id: &str, title: &str) -> Self {
        Self {
            entity,
            window_id: -1,
            pid: -1,
            bundle_id: bundle_id.to_string(),
            title: title.to_string(),
            identifier: "main".to_string(),
            role: "AXWindow".to_string(),
            subrole: "AXStandardWindow".to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WindowHardMatchKey {
    window_id: WinID,
    pid: Pid,
    bundle_id: String,
}

impl WindowHardMatchKey {
    fn new(window_id: WinID, pid: Pid, bundle_id: String) -> Self {
        Self {
            window_id,
            pid,
            bundle_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PlannedColumn {
    Single(Entity),
    Stack(Vec<PlannedStackItem>),
    Tabs(Vec<Entity>),
    Fullscreen(Entity),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PlannedStackItem {
    Single(Entity),
    Tabs(Vec<Entity>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PlannedStrip {
    pub workspace_id: WorkspaceId,
    pub display_id: Option<CGDirectDisplayID>,
    /// Stable identity of the saved display (v4+). Preferred over
    /// `display_id` when matching against live displays.
    pub display_uuid: Option<String>,
    pub virtual_index: u32,
    pub columns: Vec<PlannedColumn>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RestorePlan {
    pub strips: Vec<PlannedStrip>,
    pub active_virtual_by_workspace: HashMap<WorkspaceId, u32>,
    pub consumed_entities: HashSet<Entity>,
    pub ignored_missing_windows: usize,
    pub skipped_ambiguous_matches: usize,
}

pub(crate) struct RestorePlanner<'a> {
    state: &'a PaneruState,
    saved_hard_keys: HashSet<WindowHardMatchKey>,
}

impl<'a> RestorePlanner<'a> {
    pub(crate) fn new(state: &'a PaneruState) -> Self {
        Self {
            state,
            saved_hard_keys: saved_hard_match_keys(state),
        }
    }

    pub(crate) fn plan(&self, current: &[CurrentWindowIdentity]) -> RestorePlan {
        let mut plan = RestorePlan::default();

        for workspace in &self.state.workspaces {
            let surviving_strips = self.plan_workspace(workspace, current, &mut plan);
            Self::record_active_virtual(workspace, &surviving_strips, &mut plan);
            plan.strips.extend(surviving_strips);
        }

        plan
    }

    fn plan_workspace(
        &self,
        workspace: &SavedWorkspace,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Vec<PlannedStrip> {
        workspace
            .strips
            .iter()
            .filter_map(|strip| self.plan_strip(workspace, strip, current, plan))
            .collect()
    }

    fn plan_strip(
        &self,
        workspace: &SavedWorkspace,
        strip: &SavedStrip,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<PlannedStrip> {
        let columns = strip
            .columns
            .iter()
            .filter_map(|column| self.plan_column(column, current, plan))
            .collect::<Vec<_>>();

        (!columns.is_empty()).then_some(PlannedStrip {
            workspace_id: workspace.workspace_id,
            display_id: workspace.display_id,
            display_uuid: workspace.display_uuid.clone(),
            virtual_index: strip.virtual_index,
            columns,
        })
    }

    fn plan_column(
        &self,
        column: &SavedColumn,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<PlannedColumn> {
        match column {
            SavedColumn::Single(saved) => self
                .match_window(saved, current, plan)
                .map(PlannedColumn::Single),
            SavedColumn::Fullscreen(saved) => self
                .match_window(saved, current, plan)
                .map(PlannedColumn::Fullscreen),
            SavedColumn::Tabs(tabs) => compact_entities(
                tabs.iter()
                    .filter_map(|saved| self.match_window(saved, current, plan))
                    .collect(),
            ),
            SavedColumn::Stack(items) => compact_stack_items(
                items
                    .iter()
                    .filter_map(|item| self.plan_stack_item(item, current, plan))
                    .collect(),
            ),
        }
    }

    fn plan_stack_item(
        &self,
        item: &SavedStackItem,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<PlannedStackItem> {
        match item {
            SavedStackItem::Single(saved) => self
                .match_window(saved, current, plan)
                .map(PlannedStackItem::Single),
            SavedStackItem::Tabs(tabs) => compact_stack_tabs(
                tabs.iter()
                    .filter_map(|saved| self.match_window(saved, current, plan))
                    .collect(),
            ),
        }
    }

    fn match_window(
        &self,
        saved: &SavedWindow,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<Entity> {
        if let Some(window) = current.iter().find(|window| {
            !plan.consumed_entities.contains(&window.entity)
                && saved.hard_match(window.window_id, window.pid, &window.bundle_id)
        }) {
            plan.consumed_entities.insert(window.entity);
            return Some(window.entity);
        }

        let fallback_matches = current
            .iter()
            .filter(|window| {
                !plan.consumed_entities.contains(&window.entity)
                    && saved.fallback_match(window)
                    && !self.current_window_has_saved_hard_match(window)
            })
            .collect::<Vec<_>>();

        match fallback_matches.as_slice() {
            [window] => {
                plan.consumed_entities.insert(window.entity);
                Some(window.entity)
            }
            [] => {
                plan.ignored_missing_windows += 1;
                None
            }
            _ => {
                plan.skipped_ambiguous_matches += 1;
                None
            }
        }
    }

    fn current_window_has_saved_hard_match(&self, current: &CurrentWindowIdentity) -> bool {
        self.saved_hard_keys.contains(&current.hard_key())
    }

    fn record_active_virtual(
        workspace: &SavedWorkspace,
        surviving_strips: &[PlannedStrip],
        plan: &mut RestorePlan,
    ) {
        let Some(saved_active) = workspace.active_virtual_index else {
            if let Some(first_survivor) = surviving_strips
                .iter()
                .map(|strip| strip.virtual_index)
                .min()
            {
                plan.active_virtual_by_workspace
                    .insert(workspace.workspace_id, first_survivor);
            }
            return;
        };
        let Some(nearest_active) = surviving_strips
            .iter()
            .map(|strip| strip.virtual_index)
            .min_by_key(|virtual_index| (virtual_index.abs_diff(saved_active), *virtual_index))
        else {
            return;
        };

        plan.active_virtual_by_workspace
            .insert(workspace.workspace_id, nearest_active);
    }
}

fn saved_windows_in_state(state: &PaneruState) -> impl Iterator<Item = &SavedWindow> {
    state
        .workspaces
        .iter()
        .flat_map(|workspace| &workspace.strips)
        .flat_map(|strip| &strip.columns)
        .flat_map(saved_windows_in_column)
}

fn saved_windows_in_column(column: &SavedColumn) -> Box<dyn Iterator<Item = &SavedWindow> + '_> {
    match column {
        SavedColumn::Single(saved) | SavedColumn::Fullscreen(saved) => {
            Box::new(std::iter::once(saved))
        }
        SavedColumn::Tabs(tabs) => Box::new(tabs.iter()),
        SavedColumn::Stack(items) => Box::new(items.iter().flat_map(saved_windows_in_stack_item)),
    }
}

fn saved_windows_in_stack_item(
    item: &SavedStackItem,
) -> Box<dyn Iterator<Item = &SavedWindow> + '_> {
    match item {
        SavedStackItem::Single(saved) => Box::new(std::iter::once(saved)),
        SavedStackItem::Tabs(tabs) => Box::new(tabs.iter()),
    }
}

impl SavedWindow {
    fn hard_key(&self) -> WindowHardMatchKey {
        WindowHardMatchKey::new(self.window_id, self.pid, self.bundle_id.clone())
    }

    fn fallback_match(&self, current: &CurrentWindowIdentity) -> bool {
        !self.title.is_empty()
            && self.bundle_id == current.bundle_id
            && self.title == current.title
            && self.identifier == current.identifier
            && self.role == current.role
            && self.subrole == current.subrole
    }
}

fn saved_hard_match_keys(state: &PaneruState) -> HashSet<WindowHardMatchKey> {
    saved_windows_in_state(state)
        .map(SavedWindow::hard_key)
        .collect()
}

fn has_saved_fallback_windows(state: &PaneruState) -> bool {
    saved_windows_in_state(state).any(|window| !window.title.is_empty())
}

pub(crate) fn matches_startup_restore_state(
    window: &Window,
    app: &Application,
    session: Option<&SessionRestore>,
    restoration: Option<&PaneruState>,
    config: &Config,
) -> bool {
    if !config.restore_enabled() {
        return false;
    }

    let Ok(pid) = window.pid() else {
        return false;
    };
    let bundle_id = app.bundle_id().unwrap_or_default().clone();
    let key = WindowHardMatchKey::new(window.id(), pid, bundle_id.clone());

    if let Some(session) = session {
        return session.saved_hard_keys.contains(&key);
    }

    let Some(state) = restoration else {
        return false;
    };
    saved_windows_in_state(state).any(|saved| saved.hard_match(window.id(), pid, &bundle_id))
}

#[allow(clippy::too_many_lines)]
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
pub(super) fn restore_window_state(
    _: On<RestoreWindowState>,
    mut workspaces: Query<(Entity, &mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    displays: Query<(
        Entity,
        &Display,
        Option<&DockPosition>,
        Has<ActiveDisplayMarker>,
    )>,
    apps: Query<&Application>,
    session: Option<Res<SessionRestore>>,
    restoration: Option<Res<PaneruState>>,
    mut ctx: WindowCtx,
) {
    let restoration = if let Some(session) = session.as_deref() {
        &session.state
    } else {
        let Some(restoration) = restoration.as_deref() else {
            return;
        };
        if !ctx.config.restore_enabled() {
            info!("Session restore disabled by configuration");
            ctx.commands.remove_resource::<PaneruState>();
            return;
        }
        match ctx.config.restore_missing_windows() {
            // Drop is enforced at grace expiry (see `tick_restore_grace`),
            // not here: late launches inside the window must still match.
            MissingWindowBehavior::Ignore | MissingWindowBehavior::Drop => {}
        }
        ctx.commands.insert_resource(SessionRestore::new(
            restoration.clone(),
            ctx.config.restore_startup_grace(),
        ));
        restoration
    };

    let current = current_window_identities(&ctx.windows, &apps, restoration);
    let plan = RestorePlanner::new(restoration).plan(&current);

    if plan.consumed_entities.is_empty() {
        info!(
            "Session restore matched 0 windows; missing={}, ambiguous={}",
            plan.ignored_missing_windows, plan.skipped_ambiguous_matches
        );
        return;
    }

    let mut active_workspace_ids = HashSet::new();
    let mut emptied_existing_strips = HashSet::new();
    for (entity, mut strip, active) in &mut workspaces {
        if active {
            active_workspace_ids.insert(strip.id());
        }

        let had_consumed_window = plan
            .consumed_entities
            .iter()
            .any(|entity| strip.contains(*entity));
        for entity in &plan.consumed_entities {
            strip.remove(*entity);
        }

        // Row 0 is the row every space is created with. Emptying it is normal
        // (its windows move onto the restored rows), but despawning it leaves
        // the space numbered from "2" with no row that any later switch or
        // reap path recreates, so it is kept and reused instead.
        if had_consumed_window && strip.all_windows().is_empty() && strip.virtual_index > 0 {
            emptied_existing_strips.insert(entity);
        }
    }

    for entity in &emptied_existing_strips {
        if let Ok(mut entity_commands) = ctx.commands.get_entity(*entity) {
            entity_commands.try_despawn();
        }
    }

    for entity in &plan.consumed_entities {
        if let Ok(mut entity_commands) = ctx.commands.get_entity(*entity) {
            entity_commands.try_remove::<Unmanaged>();
        }
    }

    let mut restored_strips = 0;
    for planned in &plan.strips {
        let Some((display_entity, display, dock)) = select_display(
            planned.workspace_id,
            planned.display_id,
            planned.display_uuid.as_deref(),
            &displays,
        ) else {
            warn!(
                "Skipping restore for workspace {} virtual {} because no display exists",
                planned.workspace_id, planned.virtual_index
            );
            continue;
        };
        // Clamp oversize restores into the target viewport once at
        // placement: a window saved on a bigger display must arrive at most
        // maximized for this one, not overflow it. Only shrinks — the
        // pannable wide-column feature can still widen afterwards.
        let viewport = display.actual_display_bounds(dock, &ctx.config);
        let mut strip = layout_strip_from_plan(planned);
        for member in strip.all_windows() {
            let Some(size) = ctx.windows.size(member) else {
                continue;
            };
            let clamped = clamp_size_to_viewport(size, viewport);
            if clamped != size {
                ctx.commands.resize_entity(member, clamped);
            }
        }
        if strip.all_windows().is_empty() {
            continue;
        }

        // Keep unmatched startup windows on the same normal row. Fullscreen
        // strips must remain single-column, so leave those rows separate.
        if !strip.is_fullscreen()
            && let Some((entity, mut existing, _)) =
                workspaces.iter_mut().find(|(entity, existing, _)| {
                    !emptied_existing_strips.contains(entity)
                        && existing.id() == planned.workspace_id
                        && existing.virtual_index == planned.virtual_index
                        && !existing.is_fullscreen()
                })
        {
            strip.append_strip(&mut existing);
            // Interleave the kept startup windows by live placement: the
            // appended run was sorted at init, but it always lands after the
            // restored columns regardless of on-screen order. Whole columns
            // move, `Stack`/`Tabs` groups stay intact, and saved order wins
            // ties and unknown frames (stable `None`-last sort).
            strip.sort_columns_by_x(|entity| {
                let (_, _, unmanaged) = ctx.windows.get_managed(entity)?;
                if unmanaged.is_some() {
                    return None;
                }
                ctx.windows.frame(entity).map(|frame| frame.center().x)
            });
            emptied_existing_strips.insert(entity);
            if let Ok(mut entity_commands) = ctx.commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
        }

        let is_active = plan
            .active_virtual_by_workspace
            .get(&planned.workspace_id)
            .is_some_and(|active| *active == planned.virtual_index);
        let is_global_active = is_active && active_workspace_ids.contains(&planned.workspace_id);
        if is_active {
            for (entity, strip, _) in &mut workspaces {
                if strip.id() == planned.workspace_id
                    && !emptied_existing_strips.contains(&entity)
                    && is_global_active
                    && let Ok(mut entity_commands) = ctx.commands.get_entity(entity)
                {
                    entity_commands.try_remove::<ActiveWorkspaceMarker>();
                }
            }
        }

        let origin = if is_global_active {
            display.bounds().min
        } else {
            display.bounds().max - PARKED_STRIP_SLIVER
        };
        let previous = PreviousStripPosition {
            origin: display.bounds().min,
            focus: strip.all_windows().first().copied(),
        };

        let mut spawned =
            ctx.commands
                .spawn_layout_strip(strip, origin, display_entity, is_global_active);

        if !is_global_active {
            spawned.insert(previous);
        }

        // Snap restored windows into their slots on the first layout pass,
        // like fresh-launch windows (see `finish_setup`).
        super::workspace::spawn_snap_strip_guard(spawned.id(), &mut ctx.commands);

        restored_strips += 1;
    }

    info!(
        "Session restore applied: matched={}, strips={}, missing={}, ambiguous={}",
        plan.consumed_entities.len(),
        restored_strips,
        plan.ignored_missing_windows,
        plan.skipped_ambiguous_matches
    );
}

fn layout_strip_from_plan(planned: &PlannedStrip) -> LayoutStrip {
    if let [PlannedColumn::Fullscreen(entity)] = planned.columns.as_slice() {
        let mut strip = LayoutStrip::fullscreen(planned.workspace_id, *entity);
        strip.virtual_index = planned.virtual_index;
        return strip;
    }

    let mut strip = LayoutStrip::new(planned.workspace_id, planned.virtual_index);
    apply_planned_columns(&mut strip, &planned.columns);
    strip
}

fn current_window_identities(
    windows: &Windows,
    apps: &Query<&Application>,
    restoration: &PaneruState,
) -> Vec<CurrentWindowIdentity> {
    let mut current = windows
        .managed_iter()
        .filter_map(|(window, entity, child)| {
            let app = apps.get(child.parent()).ok()?;
            Some(CurrentWindowIdentity {
                entity,
                window_id: window.id(),
                pid: window.pid().ok()?,
                bundle_id: app.bundle_id().unwrap_or_default().clone(),
                title: String::new(),
                identifier: String::new(),
                role: String::new(),
                subrole: String::new(),
            })
        })
        .collect::<Vec<_>>();

    if has_saved_fallback_windows(restoration) {
        let saved_hard_keys = saved_hard_match_keys(restoration);
        hydrate_fallback_identities(&mut current, windows, &saved_hard_keys);
    }

    current
}

fn hydrate_fallback_identities(
    current: &mut [CurrentWindowIdentity],
    windows: &Windows,
    saved_hard_keys: &HashSet<WindowHardMatchKey>,
) {
    for identity in current {
        if saved_hard_keys.contains(&identity.hard_key()) {
            continue;
        }
        let Some(window) = windows.get(identity.entity) else {
            continue;
        };
        identity.title = window.title().unwrap_or_default();
        if identity.title.is_empty() {
            continue;
        }
        identity.identifier = window.identifier().unwrap_or_default();
        identity.role = window.role().unwrap_or_default();
        identity.subrole = window.subrole().unwrap_or_default();
    }
}

/// Picks the live display a saved workspace belongs on.
///
/// Match order:
/// 1. saved UUID (v4+) — survives numeric-id rotation on reboot/replug, so
///    windows stay on the display they were on;
/// 2. exact numeric display id (back-compat, v2/v3);
/// 3. the active display, else the lowest id — a saved display that is gone
///    (undock/reorder) lands on the display in front, clamped to its
///    viewport by the layout pass, instead of scattering by geometry guess.
fn select_display<'a>(
    workspace_id: WorkspaceId,
    planned_display_id: Option<CGDirectDisplayID>,
    planned_display_uuid: Option<&str>,
    displays: &'a Query<(
        Entity,
        &Display,
        Option<&DockPosition>,
        Has<ActiveDisplayMarker>,
    )>,
) -> Option<(Entity, &'a Display, Option<&'a DockPosition>)> {
    // 1. Stable identity first.
    if let Some(uuid) = planned_display_uuid
        && let Some(found) = displays
            .iter()
            .find(|(_, display, _, _)| display.uuid() == Some(uuid))
    {
        return Some((found.0, found.1, found.2));
    }

    // 2. Exact numeric id (v2/v3 files, or ids that didn't rotate).
    if let Some(display_id) = planned_display_id
        && let Some(found) = displays
            .iter()
            .find(|(_, display, _, _)| display.id() == display_id)
    {
        return Some((found.0, found.1, found.2));
    }

    if planned_display_id.is_some() || planned_display_uuid.is_some() {
        info!(
            "Session restore remapping workspace {workspace_id} from missing display {planned_display_id:?} to the active display"
        );
    }

    // 3. Active display, else lowest id.
    displays
        .iter()
        .find(|(_, _, _, active)| *active)
        .or_else(|| {
            displays
                .iter()
                .min_by_key(|(_, display, _, _)| display.id())
        })
        .map(|(entity, display, dock, _)| (entity, display, dock))
}

fn apply_planned_columns(strip: &mut LayoutStrip, columns: &[PlannedColumn]) {
    for column in columns {
        match column {
            PlannedColumn::Single(entity) | PlannedColumn::Fullscreen(entity) => {
                strip.append(*entity);
            }
            PlannedColumn::Tabs(entities) => {
                append_tabs(strip, entities);
            }
            PlannedColumn::Stack(items) => {
                append_stack(strip, items);
            }
        }
    }
}

fn append_tabs(strip: &mut LayoutStrip, entities: &[Entity]) -> Option<Entity> {
    let leader = *entities.first()?;
    strip.append(leader);
    for follower in &entities[1..] {
        _ = strip.convert_to_tabs(leader, *follower);
    }
    Some(leader)
}

fn append_stack(strip: &mut LayoutStrip, items: &[PlannedStackItem]) {
    let mut first = true;
    for item in items {
        let Some(leader) = append_stack_item(strip, item) else {
            continue;
        };
        if first {
            first = false;
        } else {
            _ = strip.stack(leader);
        }
    }
}

fn append_stack_item(strip: &mut LayoutStrip, item: &PlannedStackItem) -> Option<Entity> {
    match item {
        PlannedStackItem::Single(entity) => {
            strip.append(*entity);
            Some(*entity)
        }
        PlannedStackItem::Tabs(entities) => append_tabs(strip, entities),
    }
}

fn compact_entities(entities: Vec<Entity>) -> Option<PlannedColumn> {
    match entities.as_slice() {
        [] => None,
        [entity] => Some(PlannedColumn::Single(*entity)),
        _ => Some(PlannedColumn::Tabs(entities)),
    }
}

fn compact_stack_tabs(entities: Vec<Entity>) -> Option<PlannedStackItem> {
    match entities.as_slice() {
        [] => None,
        [entity] => Some(PlannedStackItem::Single(*entity)),
        _ => Some(PlannedStackItem::Tabs(entities)),
    }
}

fn compact_stack_items(items: Vec<PlannedStackItem>) -> Option<PlannedColumn> {
    match items.as_slice() {
        [] => None,
        [PlannedStackItem::Single(entity)] => Some(PlannedColumn::Single(*entity)),
        [PlannedStackItem::Tabs(entities)] => Some(PlannedColumn::Tabs(entities.clone())),
        _ => Some(PlannedColumn::Stack(items)),
    }
}
