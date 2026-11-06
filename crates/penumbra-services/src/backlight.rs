//! Backlight display brightness control via sysfs (`/sys/class/backlight`).

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const DEFAULT_BACKLIGHT_DIR: &str = "/sys/class/backlight";

fn read_first_line(path: &Path) -> io::Result<String> {
    let content = fs::read_to_string(path)?;
    Ok(content.trim().to_string())
}

fn read_level(path: &Path) -> io::Result<u32> {
    read_first_line(path)?.parse().map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, format!("invalid backlight value in {}", path.display()))
    })
}

fn read_maximum(dir: &Path) -> io::Result<u32> {
    let maximum = read_level(&dir.join("max_brightness"))?;
    if maximum == 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "backlight maximum is zero"));
    }
    Ok(maximum)
}

pub fn discover_backlight_dir() -> io::Result<PathBuf> {
    let dir = Path::new(DEFAULT_BACKLIGHT_DIR);
    if !dir.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{} does not exist", DEFAULT_BACKLIGHT_DIR),
        ));
    }

    let mut entries = fs::read_dir(dir)?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .collect::<Vec<_>>();
    entries.sort();
    entries.into_iter().next().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("no backlight device found under {}", DEFAULT_BACKLIGHT_DIR),
        )
    })
}

pub fn read_backlight_ratio() -> io::Result<f64> {
    let dir = discover_backlight_dir()?;
    let brightness_path = dir.join("brightness");
    let max_brightness = read_maximum(&dir)?;
    let cur_brightness = read_level(&brightness_path)?;
    Ok((cur_brightness as f64 / max_brightness as f64).clamp(0.0, 1.0))
}

pub fn apply_backlight_ratio(value: f64) -> io::Result<()> {
    if !value.is_finite() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "brightness must be finite"));
    }
    let dir = discover_backlight_dir()?;
    let brightness_path = dir.join("brightness");
    let max_brightness = read_maximum(&dir)?;
    let ratio = value.clamp(0.0, 1.0);
    let raw = (ratio * max_brightness as f64).round() as u32;
    fs::write(brightness_path, raw.to_string())?;
    Ok(())
}
