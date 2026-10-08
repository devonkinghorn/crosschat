#![recursion_limit = "256"]
//! Crosschat client core: a small, stable facade over matrix-rust-sdk that
//! the Flutter app talks to through flutter_rust_bridge.

pub mod client;
pub mod content;
pub mod model;

pub use client::{CrosschatClient, probe_homeserver};
pub use content::{MediaInfo, Reaction, Tapback};
pub use model::*;
