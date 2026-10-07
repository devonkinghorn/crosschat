//! crosschatd: the Crosschat host daemon.
//!
//! Supervises unmodified mautrix bridges (one process each) described by
//! YAML manifests, generates their appservice registrations, health-checks
//! and restarts them, optionally runs a bundled homeserver, and exposes a
//! small HTTP API including an authenticated provisioning proxy.

pub mod api;
pub mod auth;
pub mod bridge;
pub mod config;
pub mod daemon;
pub mod homeserver;
pub mod installer;
pub mod local;
pub mod manifest;
pub mod proxy;
pub mod registration;
pub mod secrets;
pub mod supervisor;
pub mod template;
pub mod tuwunel;
