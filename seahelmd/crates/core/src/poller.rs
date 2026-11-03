//! The scan clock: every two seconds, every registered pane's screen is read
//! from its seahelmd session and run through the scanner (`Core::poll_cycle`).
//! Every pane, every cycle: the app's "preferred worktrees every cycle, the
//! rest every third" never took effect, and polling is cheap here — one
//! snapshot request per pane, skipped by the scanner when nothing moved.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::core::Core;

pub const PERIOD: Duration = Duration::from_secs(2);

pub fn spawn(core: Arc<Core>) {
    let _ = std::thread::Builder::new().name("core-poller".into()).spawn(move || loop {
        let started = Instant::now();
        core.poll_cycle();
        std::thread::sleep(PERIOD.saturating_sub(started.elapsed()));
    });
}
