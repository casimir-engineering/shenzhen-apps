//! PROTOCOL.md's ```schema blocks, parsed and checked as the helper's suite does (`tests/SZFriendsProtocolSchema.m`):
//! every built snapshot and reply result is validated against them, including fields PROTOCOL.md does not declare.

use std::collections::{BTreeSet, HashMap};

use serde_json::Value;

#[derive(Debug)]
struct Rule {
    segments: Vec<String>,
    optional: bool,
    types: Vec<String>,
    when: Option<(String, Vec<String>)>,
    source: String,
}

#[derive(Debug, Default)]
pub struct Schemas(HashMap<String, Vec<Rule>>);

fn valid_type(token: &str) -> bool {
    ["string", "integer", "number", "bool", "object", "array", "null", "any"].contains(&token)
        || (token.starts_with("enum(") && token.ends_with(')') && token.len() > 6)
        || (token.starts_with('@') && token.len() > 1)
}

fn path_ok(path: &str) -> bool {
    !path.is_empty() && path.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '[' | ']'))
}

fn parse_rule(line: &str, source: String) -> Option<Rule> {
    let (path, rest) = line.split_once(':')?;
    let (path, optional) = match path.strip_suffix('?') {
        Some(p) => (p, true),
        None => (path, false),
    };
    if !path_ok(path) {
        return None;
    }
    let mut words = rest.split_whitespace();
    let types: Vec<String> = words.next()?.split('|').map(str::to_owned).collect();
    let when = match (words.next(), words.next(), words.next()) {
        (None, _, _) => None,
        (Some("when"), Some(condition), None) => {
            let (key, values) = condition.split_once('=')?;
            Some((key.to_owned(), values.split(',').map(str::to_owned).collect()))
        }
        _ => return None,
    };
    Some(Rule { segments: path.split('.').map(str::to_owned).collect(), optional, types, when, source })
}

impl Schemas {
    /// Parses every schema block; panics on a rule it cannot read, so a typo never turns into a rule that checks
    /// nothing.
    pub fn parse(markdown: &str) -> Self {
        let mut schemas: HashMap<String, Vec<Rule>> = HashMap::new();
        let mut current: Option<String> = None;
        for (number, raw) in markdown.lines().enumerate() {
            let line = raw.trim();
            let Some(name) = &current else {
                if let Some(name) = line.strip_prefix("```schema ") {
                    let name = name.trim().to_owned();
                    assert!(!schemas.contains_key(&name), "duplicate schema {name}");
                    schemas.insert(name.clone(), Vec::new());
                    current = Some(name);
                }
                continue;
            };
            if line == "```" {
                assert!(!schemas[name].is_empty(), "schema {name} has no rules");
                current = None;
                continue;
            }
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let rule = parse_rule(line, format!("{name} line {}", number + 1))
                .unwrap_or_else(|| panic!("PROTOCOL.md:{}: unparsable rule '{line}' in {name}", number + 1));
            for t in &rule.types {
                assert!(valid_type(t), "PROTOCOL.md:{}: unknown type {t}", number + 1);
            }
            schemas.get_mut(name).unwrap().push(rule);
        }
        assert!(current.is_none(), "a schema block is not closed");
        Self(schemas)
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Every error validating `object` against the blocks named, undeclared fields included.
    pub fn validate(&self, object: &Value, ids: &[&str], where_: &str) -> Vec<String> {
        let mut errors = Vec::new();
        for id in ids {
            self.validate_object(object, id, where_, &mut errors, 0);
        }
        self.check_undeclared(object, ids, where_, &mut errors);
        errors
    }

    fn validate_object(&self, object: &Value, id: &str, where_: &str, errors: &mut Vec<String>, depth: usize) {
        if depth > 16 {
            errors.push(format!("{where_}: types nest deeper than 16 at {id}"));
            return;
        }
        let Some(rules) = self.0.get(id) else {
            errors.push(format!("{where_}: no schema {id}"));
            return;
        };
        let optional: BTreeSet<String> =
            rules.iter().filter(|r| r.optional).map(|r| key_path(&r.segments, r.segments.len())).collect();
        for rule in rules {
            if let Some((path, values)) = &rule.when {
                let mut node = object;
                for key in path.split('.') {
                    node = node.get(key).unwrap_or(&Value::Null);
                }
                if node.is_null() {
                    continue;
                }
                let text = node.as_str().map(str::to_owned).unwrap_or_else(|| node.to_string());
                if !values.contains(&text) {
                    continue;
                }
            }
            self.walk(object, rule, 0, "", &optional, where_, errors, depth);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn walk(
        &self,
        node: &Value,
        rule: &Rule,
        index: usize,
        path: &str,
        optional: &BTreeSet<String>,
        where_: &str,
        errors: &mut Vec<String>,
        depth: usize,
    ) {
        if index == rule.segments.len() {
            self.check_value(node, rule, path, where_, errors, depth);
            return;
        }
        if node.is_null() {
            return; // the parent's rule decided whether null is allowed
        }
        let segment = &rule.segments[index];
        let fan_out = segment.ends_with("[]");
        let key = segment.trim_end_matches("[]");
        let child_path = if path.is_empty() { key.to_owned() } else { format!("{path}.{key}") };
        let Value::Object(map) = node else {
            errors.push(format!("{where_}: {path} is not an object ({})", rule.source));
            return;
        };
        let Some(child) = map.get(key) else {
            if !rule.optional && !optional.contains(&key_path(&rule.segments, index + 1)) {
                errors.push(format!("{where_}: missing {child_path} ({})", rule.source));
            }
            return;
        };
        if !fan_out {
            self.walk(child, rule, index + 1, &child_path, optional, where_, errors, depth);
            return;
        }
        match child {
            Value::Null => {}
            Value::Array(items) => {
                for (i, item) in items.iter().enumerate() {
                    self.walk(item, rule, index + 1, &format!("{child_path}[{i}]"), optional, where_, errors, depth);
                }
            }
            _ => errors.push(format!("{where_}: {child_path} is not an array ({})", rule.source)),
        }
    }

    fn matches(&self, value: &Value, kind: &str, where_: &str, errors: &mut Vec<String>, depth: usize) -> bool {
        match kind {
            "any" => true,
            "null" => value.is_null(),
            "string" => value.is_string(),
            "bool" => value.is_boolean(),
            "object" => value.is_object(),
            "array" => value.is_array(),
            "number" => value.is_number(),
            "integer" => value.is_i64() || value.is_u64(),
            _ if kind.starts_with("enum(") => {
                let list = &kind[5..kind.len() - 1];
                value.as_str().is_some_and(|v| list.split(',').any(|item| item == v))
            }
            _ => {
                if !value.is_object() {
                    return false;
                }
                let id = format!("type.{}", &kind[1..]);
                let before = errors.len();
                self.validate_object(value, &id, where_, errors, depth + 1);
                self.check_undeclared(value, &[&id], where_, errors);
                errors.len() == before
            }
        }
    }

    fn check_value(
        &self,
        value: &Value,
        rule: &Rule,
        path: &str,
        where_: &str,
        errors: &mut Vec<String>,
        depth: usize,
    ) {
        let mut best: Option<Vec<String>> = None;
        for kind in &rule.types {
            let mut trial = Vec::new();
            if self.matches(value, kind, &format!("{where_} {path}"), &mut trial, depth) {
                return;
            }
            if !trial.is_empty() && best.as_ref().is_none_or(|b| trial.len() < b.len()) {
                best = Some(trial);
            }
        }
        match best {
            Some(best) => errors.extend(best),
            None => {
                errors.push(format!("{where_}: {path} is {value}, expected {} ({})", rule.types.join("|"), rule.source))
            }
        }
    }

    fn check_undeclared(&self, object: &Value, ids: &[&str], where_: &str, errors: &mut Vec<String>) {
        let mut declared = BTreeSet::new();
        let mut stops = BTreeSet::new();
        let mut free_form = BTreeSet::new();
        for id in ids {
            for rule in self.0.get(*id).into_iter().flatten() {
                for n in 1..=rule.segments.len() {
                    declared.insert(key_path(&rule.segments, n));
                }
                let full = key_path(&rule.segments, rule.segments.len());
                let typed = rule.types.iter().any(|t| t.starts_with('@'));
                let container_only =
                    rule.types.iter().all(|t| t.starts_with('@') || ["object", "any", "null"].contains(&t.as_str()));
                if typed {
                    stops.insert(full);
                } else if container_only {
                    free_form.insert(full);
                }
            }
        }
        for path in free_form {
            let prefix = format!("{path}.");
            if !declared.iter().any(|d: &String| d.starts_with(&prefix)) {
                stops.insert(path);
            }
        }
        walk_undeclared(object, "", &declared, &stops, where_, errors);
    }
}

fn key_path(segments: &[String], count: usize) -> String {
    segments[..count].iter().map(|s| s.trim_end_matches("[]")).collect::<Vec<_>>().join(".")
}

fn walk_undeclared(
    node: &Value,
    path: &str,
    declared: &BTreeSet<String>,
    stops: &BTreeSet<String>,
    where_: &str,
    errors: &mut Vec<String>,
) {
    match node {
        Value::Array(items) => {
            for item in items {
                walk_undeclared(item, path, declared, stops, where_, errors);
            }
        }
        Value::Object(map) if path.is_empty() || !stops.contains(path) => {
            for (key, child) in map {
                let child_path = if path.is_empty() { key.clone() } else { format!("{path}.{key}") };
                if declared.contains(&child_path) {
                    walk_undeclared(child, &child_path, declared, stops, where_, errors);
                } else {
                    errors.push(format!("{where_}: {child_path} is not declared in PROTOCOL.md"));
                }
            }
        }
        _ => {}
    }
}
