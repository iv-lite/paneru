use std::{
    env, fs,
    io::{Error, ErrorKind, Result, Write},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

use tracing::{info, warn};

use crate::util::exe_path;

/// The bundle identifier for the `paneru` service.
pub const ID: &str = "com.github.karinushka.paneru";

/// Stable ad-hoc signing identifier stamped on the canonical binary, so
/// re-granted TCC entries at least show a stable name. The hash still
/// changes per build (ad-hoc), so every update needs one fresh grant —
/// without a paid Developer ID there is no way around that.
pub const SIGN_IDENTIFIER: &str = "com.github.karinushka.paneru";

/// Location of the single canonical daemon binary, relative to `$HOME`.
/// Every install vector converges here: `paneru install` copies the
/// invoking binary over it, and the launchd plist plus the
/// `Paneru.app` shim point at it once and never drift.
pub const CANONICAL_BIN_REL: &str = ".local/bin/paneru";

/// Absolute canonical daemon path for `home`.
#[must_use]
pub fn canonical_path(home: &Path) -> PathBuf {
    home.join(CANONICAL_BIN_REL)
}

/// Extracts the `Program` entry from launchd plist text. Pure so the
/// drift check is unit testable; returns `None` when absent/unparseable.
#[must_use]
pub fn parse_program(plist: &str) -> Option<String> {
    let key = "<key>Program</key>";
    let start = plist.find(key)? + key.len();
    let rest = plist[start..].trim_start();
    rest.strip_prefix("<string>")
        .and_then(|s| s.find("</string>").map(|end| s[..end].to_string()))
}

/// Extracts the signing `Identifier=` from `codesign -d` output. Pure for
/// tests; `None` when unsigned or unparseable.
#[must_use]
pub fn parse_identifier(codesign_output: &str) -> Option<String> {
    codesign_output
        .lines()
        .find_map(|line| line.trim().strip_prefix("Identifier="))
        .map(ToString::to_string)
}

/// `Service` manages the installation, uninstallation, starting, and stopping of the `paneru` application as a launchd service.
/// It encapsulates the `launchctl::Service` and the path to the executable.
#[derive(Debug)]
pub struct Service {
    /// The underlying `launchctl::Service` instance.
    pub raw: launchctl::Service,
    /// The absolute path to the invoking `paneru` executable (copy source).
    pub bin_path: PathBuf,
    /// The absolute canonical daemon path (`~/.local/bin/paneru`) that the
    /// plist and the app shim point at.
    pub canonical: PathBuf,
    /// The user's home directory.
    home_dir: PathBuf,
}

impl Service {
    /// Creates a new `Service` instance.
    /// It determines the executable path and constructs the `launchctl::Service` with appropriate settings.
    ///
    /// # Arguments
    ///
    /// * `name` - The name of the service (e.g., "com.github.karinushka.paneru").
    ///
    /// # Returns
    ///
    /// `Ok(Self)` if the service is created successfully, otherwise `Err(Error)` if the executable path or home directory cannot be found.
    pub fn try_new(name: &str) -> Result<Self> {
        let home_dir = env::home_dir().ok_or(Error::new(
            ErrorKind::NotFound,
            "Cannot find home directory.",
        ))?;
        let bin_path = exe_path().ok_or(Error::new(
            ErrorKind::NotFound,
            "Cannot find current executable path.",
        ))?;
        let canonical = canonical_path(&home_dir);
        Ok(Self {
            raw: launchctl::Service::builder()
                .name(name)
                .uid(unsafe { libc::getuid() }.to_string())
                .plist_path(format!(
                    "{home}/Library/LaunchAgents/{name}.plist",
                    home = home_dir.display()
                ))
                .build(),
            bin_path,
            canonical,
            home_dir,
        })
    }

    /// Returns the path to the launchd plist file for this service.
    #[must_use]
    pub fn plist_path(&self) -> &Path {
        Path::new(&self.raw.plist_path)
    }

    /// Checks if the service is currently installed (i.e., its plist file exists).
    #[must_use]
    pub fn is_installed(&self) -> bool {
        self.plist_path().is_file()
    }

    /// Installs the service as a launch agent by writing its plist file.
    /// Doubles as the updater: converges the invoking binary onto the
    /// canonical path (copy + ad-hoc re-stamp when the bytes differ) and
    /// rewrites the plist whenever it is missing or its `Program=` drifted
    /// from canonical. Never starts the service — follow with `paneru
    /// restart` (which heals a bootstrapped stale definition).
    ///
    /// # Returns
    ///
    /// `Ok(())` if everything already converges, otherwise `Err(Error)` on
    /// file system or signing errors.
    pub fn install(&self) -> Result<()> {
        self.promote_to_canonical()?;
        self.warn_if_not_on_path();
        if self.is_installed() && !self.plist_drifted() {
            warn!(
                "launch agent at `{}` already points at the canonical binary, nothing to do",
                self.plist_path().display()
            );
            return Ok(());
        }
        self.write_plist()?;
        if self.is_bootstrapped().unwrap_or(false) {
            warn!(
                "service is loaded with a stale definition; run `paneru restart` to pick up {}",
                self.canonical.display()
            );
        }
        Ok(())
    }

    /// Reads the installed plist's `Program=` entry, if any.
    #[must_use]
    pub fn installed_program(&self) -> Option<String> {
        fs::read_to_string(self.plist_path())
            .ok()
            .and_then(|text| parse_program(&text))
    }

    /// Whether the installed plist points somewhere other than canonical
    /// (missing plist counts as drifted so callers converge it).
    #[must_use]
    pub fn plist_drifted(&self) -> bool {
        self.installed_program()
            .is_none_or(|program| program != self.canonical.display().to_string())
    }

    fn write_plist(&self) -> Result<()> {
        let plist_path = self.plist_path();
        let dir = plist_path.parent().ok_or(Error::last_os_error())?;
        if !dir.exists() {
            fs::create_dir_all(dir)?;
        }
        let mut plist = fs::File::create(plist_path)?;
        plist.write_all(self.launchd_plist().as_bytes())?;
        info!(
            "installed launch agent at `{}` pointing at `{}`",
            plist_path.display(),
            self.canonical.display()
        );
        info!("check logfile /tmp/com.github.karinushka.paneru*.log for potential error messages");
        Ok(())
    }

    /// Copies the invoking binary over the canonical path (atomic
    /// temp+rename, safe while the old daemon runs) and re-stamps the
    /// stable ad-hoc identifier when the bytes or the identifier differ.
    /// Skips both when the canonical binary already matches, so a plain
    /// `paneru install` never gratuitously invalidates a live TCC grant.
    fn promote_to_canonical(&self) -> Result<()> {
        let canonical = &self.canonical;
        if let Some(parent) = canonical.parent()
            && !parent.exists()
        {
            fs::create_dir_all(parent)?;
        }
        let current_bytes = fs::read(&self.bin_path)?;
        let canonical_bytes = fs::read(canonical).unwrap_or_default();
        if current_bytes != canonical_bytes {
            let staging = canonical.with_extension("new");
            fs::write(&staging, &current_bytes)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mut permissions = fs::metadata(&staging)?.permissions();
                permissions.set_mode(0o755);
                fs::set_permissions(&staging, permissions)?;
            }
            fs::rename(&staging, canonical)?;
            info!("installed daemon binary to `{}`", canonical.display());
        }
        if Self::signature_identifier(canonical)? != SIGN_IDENTIFIER {
            stamp_signature(canonical)?;
        }
        Ok(())
    }

    /// Signing identifier currently stamped on `path` (`None` when the
    /// `codesign` probe itself fails).
    fn signature_identifier(path: &Path) -> Result<String> {
        let output = Command::new("/usr/bin/codesign")
            .args(["-d", "--verbose=2"])
            .arg(path)
            .output()?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        Ok(parse_identifier(&text).unwrap_or_default())
    }

    /// Warns once when the canonical dir is not on `PATH`.
    fn warn_if_not_on_path(&self) {
        let Some(parent) = self.canonical.parent() else {
            return;
        };
        let on_path =
            env::var("PATH").is_ok_and(|path| env::split_paths(&path).any(|entry| entry == parent));
        if !on_path {
            warn!(
                "canonical daemon `{}` is not on PATH; add `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile",
                self.canonical.display()
            );
        }
    }

    /// Uninstalls the service by removing its plist file.
    /// If the service is not installed, a warning is logged, and uninstallation is skipped.
    /// It also attempts to stop the service before removing the file.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service is uninstalled successfully or not found, otherwise `Err(Error)` if a file system error occurs.
    pub fn uninstall(&self) -> Result<()> {
        let plist_path = self.plist_path();
        if !self.is_installed() {
            warn!(
                "no launch agent detected at `{}`, skipping uninstallation",
                plist_path.display(),
            );
            return Ok(());
        }

        if let Err(e) = self.stop() {
            warn!("failed to stop service: {e:?}");
        }

        fs::remove_file(plist_path)?;
        info!(
            "removed existing launch agent at `{}`",
            plist_path.display()
        );
        Ok(())
    }

    /// Reinstalls the service by first uninstalling it and then installing it again.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service is reinstalled successfully, otherwise `Err(Error)` from underlying install/uninstall operations.
    pub fn reinstall(&self) -> Result<()> {
        self.uninstall()?;
        self.install()
    }

    /// Starts the service using `launchctl`.
    /// Heals a drifted plist first (rewrite + bootout so the new `Program=`
    /// takes effect), then enables/bootstraps or kickstarts as before.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service starts successfully, otherwise `Err(Error)` from `launchctl`.
    pub fn start(&self) -> Result<()> {
        if !self.is_installed() || self.plist_drifted() {
            if self.is_bootstrapped().unwrap_or(false) {
                let _ = Self::launchctl(&["bootout", self.raw.service_target.as_str()]);
            }
            self.write_plist()?;
        }
        info!("starting service...");
        self.create_log_files()?;
        for args in start_commands(&self.raw, self.is_bootstrapped()?) {
            Self::run_launchctl(&args)?;
        }
        info!("service started");
        Ok(())
    }

    fn create_log_files(&self) -> Result<()> {
        for path in [&self.raw.error_log_path, &self.raw.out_log_path] {
            if !Path::new(path).exists() {
                fs::File::create(path)?;
            }
        }
        Ok(())
    }

    fn is_bootstrapped(&self) -> Result<bool> {
        let output = Self::launchctl(&["print", self.raw.service_target.as_str()])?;
        Ok(output.status.success())
    }

    fn run_launchctl(args: &[&str]) -> Result<()> {
        let output = Self::launchctl(args)?;
        if output.status.success() {
            return Ok(());
        }

        Err(Error::other(format!(
            "launchctl {} failed with {}: {}",
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )))
    }

    fn launchctl(args: &[&str]) -> Result<Output> {
        Command::new("/bin/launchctl").args(args).output()
    }

    /// Stops the service using `launchctl`.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service stops successfully, otherwise `Err(Error)` from `launchctl`.
    pub fn stop(&self) -> Result<()> {
        info!("stopping service...");
        self.raw.stop()?;
        info!("service stopped");
        Ok(())
    }

    /// Restarts the service by first stopping it and then starting it again.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service restarts successfully, otherwise `Err(Error)` from underlying stop/start operations.
    pub fn restart(&self) -> Result<()> {
        self.stop()?;
        self.start()
    }

    /// Spawns a detached `paneru restart` subprocess.
    /// Used by the in-daemon restart command so launchctl stop/start runs outside
    /// the process being stopped.
    pub fn request_restart() -> Result<()> {
        let bin_path = exe_path().ok_or(Error::new(
            ErrorKind::NotFound,
            "Cannot find current executable path.",
        ))?;
        Command::new(bin_path)
            .arg("restart")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        Ok(())
    }

    /// Generates the content of the launchd plist file for this service.
    /// `Program` always points at the canonical daemon path, never at the
    /// invoking binary's location (Cellar paths, tarball dirs, …).
    #[must_use]
    pub fn launchd_plist(&self) -> String {
        let xdg_config_home = env::var("XDG_CONFIG_HOME")
            .unwrap_or_else(|_| format!("{}/.config", self.home_dir.display()));
        let rust_log = env::var("RUST_LOG").unwrap_or_else(|_| "info".to_string());
        format!(
            include_str!("../../assets/launchd.plist"),
            name = self.raw.name,
            bin_path = self.canonical.display(),
            out_log_path = self.raw.out_log_path,
            error_log_path = self.raw.error_log_path,
            xdg_config_home = xdg_config_home,
            rust_log = rust_log,
        )
    }
}

/// Re-stamps the stable ad-hoc identifier on `path`. Required after every
/// byte change (a copied signature never survives new bytes); without a
/// paid Developer ID this is the closest macOS gets to a stable identity.
fn stamp_signature(path: &Path) -> Result<()> {
    let output = Command::new("/usr/bin/codesign")
        .args(["--force", "--sign", "-", "--identifier", SIGN_IDENTIFIER])
        .arg(path)
        .output()?;
    if output.status.success() {
        return Ok(());
    }
    Err(Error::other(format!(
        "codesign failed for {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr).trim()
    )))
}

fn start_commands(service: &launchctl::Service, bootstrapped: bool) -> Vec<Vec<&str>> {
    if bootstrapped {
        vec![vec!["kickstart", service.service_target.as_str()]]
    } else {
        vec![
            vec!["enable", service.service_target.as_str()],
            vec![
                "bootstrap",
                service.domain_target.as_str(),
                service.plist_path.as_str(),
            ],
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_identifier, parse_program, start_commands};
    use std::path::Path;

    fn service() -> launchctl::Service {
        launchctl::Service::builder()
            .name("com.github.karinushka.paneru")
            .uid("501")
            .plist_path("/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist")
            .build()
    }

    #[test]
    fn start_kickstarts_a_bootstrapped_service_by_service_target() {
        assert_eq!(
            start_commands(&service(), true),
            vec![vec!["kickstart", "gui/501/com.github.karinushka.paneru"]]
        );
    }

    #[test]
    fn start_enables_and_bootstraps_an_unloaded_service() {
        assert_eq!(
            start_commands(&service(), false),
            vec![
                vec!["enable", "gui/501/com.github.karinushka.paneru"],
                vec![
                    "bootstrap",
                    "gui/501",
                    "/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist"
                ]
            ]
        );
    }

    #[test]
    fn parse_program_reads_the_daemon_path() {
        let plist = "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<plist version=\"1.0\"><dict>\n\
<key>Label</key><string>com.github.karinushka.paneru</string>\n\
<key>Program</key>\n<string>/Users/test/.local/bin/paneru</string>\n\
</dict></plist>\n";
        assert_eq!(
            parse_program(plist),
            Some("/Users/test/.local/bin/paneru".to_string())
        );
        assert_eq!(parse_program("<plist></plist>"), None);
        assert_eq!(parse_program("not xml at all"), None);
    }

    #[test]
    fn parse_identifier_reads_codesign_output() {
        let output = "Executable=/Users/test/.local/bin/paneru\n\
            Identifier=com.github.karinushka.paneru\n\
            Format=Mach-O thin (arm64)\n\
            Signature=adhoc\n";
        assert_eq!(
            parse_identifier(output),
            Some("com.github.karinushka.paneru".to_string())
        );
        assert_eq!(parse_identifier("garbage"), None);
    }

    #[test]
    fn canonical_path_lives_under_home() {
        assert_eq!(
            super::canonical_path(Path::new("/Users/test")),
            Path::new("/Users/test/.local/bin/paneru")
        );
    }
}
