//! Minimal `{{placeholder}}` renderer for manifests.
//!
//! Only identifiers like `{{data_dir}}` or `{{hs.server_name}}` are
//! substituted. Go-template syntax used by the bridges themselves (for example
//! `{{.}}` in `username_template`) is left untouched, so manifests can embed
//! bridge config verbatim.

use regex::Regex;
use serde_yaml_ng::Value;
use std::collections::BTreeMap;
use std::sync::LazyLock;

static PLACEHOLDER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_.:-]*)\s*\}\}").unwrap());

pub type Context = BTreeMap<String, String>;

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum TemplateError {
    #[error("unknown template variable `{0}`")]
    Unknown(String),
}

pub fn render(input: &str, ctx: &Context) -> Result<String, TemplateError> {
    let mut err = None;
    let out = PLACEHOLDER.replace_all(input, |caps: &regex::Captures| {
        let key = &caps[1];
        match ctx.get(key) {
            Some(v) => v.clone(),
            None => {
                err.get_or_insert_with(|| TemplateError::Unknown(key.to_string()));
                caps[0].to_string()
            }
        }
    });
    match err {
        Some(e) => Err(e),
        None => Ok(out.into_owned()),
    }
}

/// Render every string (keys and values) inside a YAML tree. A scalar that is
/// exactly one placeholder whose value parses as an integer or boolean is
/// converted to that type, so `port: "{{port}}"` becomes `port: 29336`.
pub fn render_value(value: &Value, ctx: &Context) -> Result<Value, TemplateError> {
    Ok(match value {
        Value::String(s) => {
            let rendered = render(s, ctx)?;
            let whole = PLACEHOLDER
                .find(s)
                .is_some_and(|m| m.start() == 0 && m.end() == s.len());
            if whole {
                if let Ok(i) = rendered.parse::<i64>() {
                    Value::Number(i.into())
                } else if let Ok(b) = rendered.parse::<bool>() {
                    Value::Bool(b)
                } else {
                    Value::String(rendered)
                }
            } else {
                Value::String(rendered)
            }
        }
        Value::Sequence(seq) => Value::Sequence(
            seq.iter()
                .map(|v| render_value(v, ctx))
                .collect::<Result<_, _>>()?,
        ),
        Value::Mapping(map) => {
            let mut out = serde_yaml_ng::Mapping::new();
            for (k, v) in map {
                out.insert(render_value(k, ctx)?, render_value(v, ctx)?);
            }
            Value::Mapping(out)
        }
        Value::Tagged(t) => render_value(&t.value, ctx)?,
        other => other.clone(),
    })
}

/// Deep-merge `overlay` into `base`: mappings merge recursively, everything
/// else (including sequences) is replaced.
pub fn deep_merge(base: &mut Value, overlay: &Value) {
    match (base, overlay) {
        (Value::Mapping(b), Value::Mapping(o)) => {
            for (k, v) in o {
                match b.get_mut(k) {
                    Some(existing) => deep_merge(existing, v),
                    None => {
                        b.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        (b, o) => *b = o.clone(),
    }
}

/// Set a value at a dotted path, creating intermediate mappings.
pub fn set_path(root: &mut Value, path: &[&str], value: Value) {
    if path.is_empty() {
        *root = value;
        return;
    }
    if !root.is_mapping() {
        *root = Value::Mapping(Default::default());
    }
    let map = root.as_mapping_mut().unwrap();
    let key = Value::String(path[0].to_string());
    let entry = map.entry(key).or_insert(Value::Null);
    set_path(entry, &path[1..], value);
}

pub fn get_path<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut cur = root;
    for p in path {
        cur = cur.as_mapping()?.get(*p)?;
    }
    Some(cur)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> Context {
        [
            ("data_dir", "/d"),
            ("port", "29336"),
            ("hs.server_name", "example.com"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    #[test]
    fn renders_and_preserves_go_templates() {
        assert_eq!(
            render("{{data_dir}}/config.yaml", &ctx()).unwrap(),
            "/d/config.yaml"
        );
        assert_eq!(
            render("gmessages_{{.}}", &ctx()).unwrap(),
            "gmessages_{{.}}"
        );
        assert_eq!(
            render("{{ hs.server_name }}", &ctx()).unwrap(),
            "example.com"
        );
    }

    #[test]
    fn unknown_variable_is_an_error() {
        assert_eq!(
            render("{{nope}}", &ctx()),
            Err(TemplateError::Unknown("nope".into()))
        );
    }

    #[test]
    fn value_rendering_coerces_whole_scalars() {
        let v: Value =
            serde_yaml_ng::from_str("port: '{{port}}'\naddr: 'http://x:{{port}}'").unwrap();
        let r = render_value(&v, &ctx()).unwrap();
        assert_eq!(r["port"], Value::Number(29336.into()));
        assert_eq!(r["addr"], Value::String("http://x:29336".into()));
    }

    #[test]
    fn deep_merge_and_paths() {
        let mut base: Value = serde_yaml_ng::from_str("a: {b: 1, c: 2}\nl: [1, 2]").unwrap();
        let over: Value = serde_yaml_ng::from_str("a: {c: 3, d: 4}\nl: [9]").unwrap();
        deep_merge(&mut base, &over);
        assert_eq!(base["a"]["b"], Value::Number(1.into()));
        assert_eq!(base["a"]["c"], Value::Number(3.into()));
        assert_eq!(base["a"]["d"], Value::Number(4.into()));
        assert_eq!(base["l"], serde_yaml_ng::from_str::<Value>("[9]").unwrap());
        set_path(&mut base, &["x", "y", "z"], Value::Bool(true));
        assert_eq!(get_path(&base, &["x", "y", "z"]), Some(&Value::Bool(true)));
    }
}
