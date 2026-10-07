//! The crosschatd vault: per-bridge secrets stored in a 0600 JSON file.
//! Appservice tokens and provisioning secrets never leave the host.

use crate::registration::{Tokens, random_token};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BridgeSecrets {
    pub tokens: Tokens,
    pub provisioning_secret: String,
    pub pickle_key: String,
}

impl BridgeSecrets {
    fn generate() -> Self {
        Self {
            tokens: Tokens::generate(),
            provisioning_secret: random_token(),
            pickle_key: random_token(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VaultData {
    #[serde(default)]
    pub bridges: BTreeMap<String, BridgeSecrets>,
    #[serde(default)]
    pub doublepuppet_as_token: Option<String>,
    #[serde(default)]
    pub admin_token: Option<String>,
    #[serde(default)]
    pub hs_registration_token: Option<String>,
}

pub struct Vault {
    path: PathBuf,
    pub data: VaultData,
}

pub fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

impl Vault {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        let data = if path.exists() {
            serde_json::from_slice(&std::fs::read(&path)?)?
        } else {
            VaultData::default()
        };
        Ok(Self { path, data })
    }

    pub fn save(&self) -> Result<()> {
        write_private(&self.path, &serde_json::to_vec_pretty(&self.data)?)
    }

    /// Get or create secrets for a bridge (persisted immediately).
    pub fn bridge(&mut self, id: &str) -> Result<BridgeSecrets> {
        if let Some(s) = self.data.bridges.get(id) {
            return Ok(s.clone());
        }
        let s = BridgeSecrets::generate();
        self.data.bridges.insert(id.to_string(), s.clone());
        self.save()?;
        Ok(s)
    }

    fn get_or_create(
        &mut self,
        f: impl Fn(&mut VaultData) -> &mut Option<String>,
    ) -> Result<String> {
        if let Some(v) = f(&mut self.data).clone() {
            return Ok(v);
        }
        let v = random_token();
        *f(&mut self.data) = Some(v.clone());
        self.save()?;
        Ok(v)
    }

    pub fn doublepuppet_token(&mut self) -> Result<String> {
        self.get_or_create(|d| &mut d.doublepuppet_as_token)
    }

    pub fn admin_token(&mut self) -> Result<String> {
        self.get_or_create(|d| &mut d.admin_token)
    }

    pub fn hs_registration_token(&mut self) -> Result<String> {
        self.get_or_create(|d| &mut d.hs_registration_token)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vault_persists_and_is_private() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("vault.json");
        let s1 = {
            let mut v = Vault::open(&p).unwrap();
            let s = v.bridge("slack").unwrap();
            v.admin_token().unwrap();
            s
        };
        let mut v2 = Vault::open(&p).unwrap();
        assert_eq!(v2.bridge("slack").unwrap(), s1);
        assert_ne!(v2.bridge("groupme").unwrap(), s1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }
}
