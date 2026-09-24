use serde::Deserialize;

#[derive(Deserialize, Clone, Debug, Default)]
pub struct GapsOptions {
    /// Between-window gaps (in pixels): per-window inset applied to every
    /// tiled window. The visual gap between neighbors is the sum of the
    /// adjacent insets. Per-rule `horizontal_padding` wins over this;
    /// a rule value (including 0) opts that app out of the global.
    /// Default: 8 on both axes.
    pub horizontal: Option<u16>,
    /// See `horizontal`.
    pub vertical: Option<u16>,
}
