use std::{
    env, fs,
    io::{Error, ErrorKind, Result},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
};

use tracing::info;

use crate::platform::service;
use crate::util::exe_path;

const APP_BUNDLE_NAME: &str = "Paneru.app";
const APP_EXECUTABLE_NAME: &str = "PaneruLauncher";
const APP_BUNDLE_ID: &str = "com.github.karinushka.paneru.launcher";

pub struct AppLauncher {
    paneru_path: PathBuf,
    app_path: PathBuf,
}

impl AppLauncher {
    pub fn try_new() -> Result<Self> {
        let home_dir = env::home_dir().ok_or(Error::new(
            ErrorKind::NotFound,
            "Cannot find home directory.",
        ))?;
        // Prefer the canonical daemon path: the shim survives updates only
        // when it points at `~/.local/bin/paneru` instead of wherever the
        // invoking binary happens to live (Cellar, tarball dir, …).
        let canonical = service::canonical_path(&home_dir);
        let paneru_path = if canonical.is_file() {
            canonical
        } else {
            exe_path().ok_or(Error::new(
                ErrorKind::NotFound,
                "Cannot find current executable path.",
            ))?
        };
        Ok(Self::new(
            paneru_path,
            home_dir.join("Applications").join(APP_BUNDLE_NAME),
        ))
    }

    fn new(paneru_path: PathBuf, app_path: PathBuf) -> Self {
        Self {
            paneru_path,
            app_path,
        }
    }

    pub fn install(&self) -> Result<()> {
        let parent = self.app_path.parent().ok_or(Error::new(
            ErrorKind::InvalidInput,
            "Application bundle path has no parent",
        ))?;
        fs::create_dir_all(parent)?;

        let staging_path = parent.join(format!(".{APP_BUNDLE_NAME}.new"));
        if staging_path.exists() {
            fs::remove_dir_all(&staging_path)?;
        }

        self.write_bundle(&staging_path)?;
        sign_bundle(&staging_path)?;

        if self.app_path.exists() {
            ensure_owned_bundle(&self.app_path)?;
            fs::remove_dir_all(&self.app_path)?;
        }
        fs::rename(&staging_path, &self.app_path)?;
        info!("installed app launcher to `{}`", self.app_path.display());
        Ok(())
    }

    pub fn uninstall(&self) -> Result<()> {
        if !self.app_path.exists() {
            return Ok(());
        }
        ensure_owned_bundle(&self.app_path)?;
        fs::remove_dir_all(&self.app_path)?;
        info!("removed app launcher from `{}`", self.app_path.display());
        Ok(())
    }

    /// Whether the installed shim points somewhere other than this
    /// launcher's daemon path. A missing or unparseable shim counts as
    /// stale so callers converge it via `install`. Never fails — I/O
    /// errors read as stale.
    #[must_use]
    pub fn shim_stale(&self) -> bool {
        let script_path = self
            .app_path
            .join("Contents/MacOS")
            .join(APP_EXECUTABLE_NAME);
        let Ok(script) = fs::read_to_string(&script_path) else {
            return true;
        };
        shim_target(&script).is_none_or(|target| target != self.paneru_path)
    }

    fn write_bundle(&self, app_path: &Path) -> Result<()> {
        let contents_path = app_path.join("Contents");
        let executable_dir = contents_path.join("MacOS");
        fs::create_dir_all(&executable_dir)?;
        fs::write(contents_path.join("Info.plist"), info_plist())?;

        let executable_path = executable_dir.join(APP_EXECUTABLE_NAME);
        fs::write(
            &executable_path,
            launcher_script(self.paneru_path.as_path()),
        )?;
        let mut permissions = fs::metadata(&executable_path)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(executable_path, permissions)
    }
}

fn ensure_owned_bundle(app_path: &Path) -> Result<()> {
    let plist = fs::read_to_string(app_path.join("Contents/Info.plist"))?;
    if plist.contains(&format!("<string>{APP_BUNDLE_ID}</string>")) {
        return Ok(());
    }

    Err(Error::new(
        ErrorKind::AlreadyExists,
        format!(
            "refusing to replace application not owned by Paneru: {}",
            app_path.display()
        ),
    ))
}

fn info_plist() -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Paneru</string>
    <key>CFBundleExecutable</key>
    <string>{APP_EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>{APP_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Paneru</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>{}</string>
    <key>CFBundleVersion</key>
    <string>{}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
  </dict>
</plist>
"#,
        env!("CARGO_PKG_VERSION"),
        env!("CARGO_PKG_VERSION"),
    )
}

fn launcher_script(paneru_path: &Path) -> String {
    format!(
        "#!/bin/sh\nexec {} start\n",
        shell_quote(&paneru_path.to_string_lossy())
    )
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

/// Extracts the daemon path a launcher script `exec`s. Inverse of
/// [`launcher_script`] (single-quote unwrapping); `None` when unparseable.
fn shim_target(script: &str) -> Option<PathBuf> {
    let line = script
        .lines()
        .map(str::trim_start)
        .find(|line| line.starts_with("exec "))?;
    let quoted = line
        .strip_prefix("exec ")?
        .trim()
        .strip_suffix(" start")?
        .trim();
    let inner = quoted.strip_prefix('\'')?.strip_suffix('\'')?;
    Some(PathBuf::from(inner.replace("'\"'\"'", "'")))
}

fn sign_bundle(app_path: &Path) -> Result<()> {
    let output = Command::new("/usr/bin/codesign")
        .args(["--force", "--deep", "--sign", "-"])
        .arg(app_path)
        .output()?;
    if output.status.success() {
        return Ok(());
    }

    Err(Error::other(format!(
        "codesign failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    )))
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };

    use super::{
        APP_BUNDLE_ID, APP_EXECUTABLE_NAME, AppLauncher, ensure_owned_bundle, launcher_script,
        shell_quote, shim_target,
    };

    static NEXT_TEST_ID: AtomicU64 = AtomicU64::new(0);

    fn test_directory() -> PathBuf {
        let test_id = NEXT_TEST_ID.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "paneru-launcher-test-{}-{test_id}",
            std::process::id()
        ))
    }

    #[test]
    fn launcher_script_quotes_the_paneru_path() {
        let script = launcher_script(PathBuf::from("/tmp/Paneru's bin").as_path());
        assert_eq!(script, "#!/bin/sh\nexec '/tmp/Paneru'\"'\"'s bin' start\n");
        assert_eq!(shell_quote("paneru"), "'paneru'");
    }

    #[test]
    fn shim_target_round_trips_launcher_script() {
        for path in [
            "/Users/test/.local/bin/paneru",
            "/opt/homebrew/bin/paneru",
            "/tmp/Paneru's bin",
        ] {
            let script = launcher_script(PathBuf::from(path).as_path());
            assert_eq!(shim_target(&script), Some(PathBuf::from(path)));
        }
        assert_eq!(shim_target("nothing to parse"), None);
        assert_eq!(
            shim_target("#!/bin/sh\nexec '/a/b' stop\n"),
            None,
            "only `start` shims parse"
        );
    }

    #[test]
    fn write_bundle_creates_a_launchable_application() {
        let root = test_directory();
        let app_path = root.join("Paneru.app");
        let launcher =
            AppLauncher::new(PathBuf::from("/opt/homebrew/bin/paneru"), app_path.clone());

        launcher.write_bundle(&app_path).unwrap();

        let plist = fs::read_to_string(app_path.join("Contents/Info.plist")).unwrap();
        assert!(plist.contains(APP_BUNDLE_ID));
        assert!(plist.contains("<string>APPL</string>"));
        assert!(plist.contains("<key>LSUIElement</key>"));

        let executable = app_path.join("Contents/MacOS").join(APP_EXECUTABLE_NAME);
        assert_eq!(
            fs::read_to_string(&executable).unwrap(),
            "#!/bin/sh\nexec '/opt/homebrew/bin/paneru' start\n"
        );
        assert_ne!(
            fs::metadata(executable).unwrap().permissions().mode() & 0o111,
            0
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn owned_bundle_check_rejects_an_unrelated_application() {
        let root = test_directory();
        let app_path = root.join("Paneru.app");
        fs::create_dir_all(app_path.join("Contents")).unwrap();
        fs::write(
            app_path.join("Contents/Info.plist"),
            "<plist><string>com.example.unrelated</string></plist>",
        )
        .unwrap();

        assert_eq!(
            ensure_owned_bundle(&app_path).unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn install_replaces_owned_bundle_and_uninstall_removes_it() {
        let root = test_directory();
        let app_path = root.join("Applications/Paneru.app");
        let launcher = AppLauncher::new(PathBuf::from("/usr/bin/true"), app_path.clone());

        launcher.install().unwrap();
        launcher.install().unwrap();

        assert!(app_path.is_dir());
        assert!(app_path.join("Contents/_CodeSignature").is_dir());

        launcher.uninstall().unwrap();
        assert!(!app_path.exists());

        fs::remove_dir_all(root).unwrap();
    }
}
