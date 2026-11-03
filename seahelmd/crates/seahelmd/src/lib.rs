//! seahelmd: one daemon per terminal session, owning the PTY and the screen
//! it draws, so the app can come and go without taking the work with it.

pub mod client;
pub mod daemon;
pub mod platform;
pub mod proto;
pub mod session;
