//! The settings table as sync reads and writes it (`-setting:`), with our own presence secret, which is one of them.

use rusqlite::types::Value;
use rusqlite::{params, Connection, OptionalExtension};

use super::Result;

/// The settings table (`-setting:`), e.g. `own_presence_secret`.
pub fn setting(conn: &Connection, key: &str) -> Result<Value> {
    let value = conn.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0)).optional()?;
    Ok(value.unwrap_or(Value::Null))
}

pub fn set_setting(conn: &Connection, key: &str, value: Value) -> Result<()> {
    if value == Value::Null {
        conn.execute("DELETE FROM settings WHERE key = ?1", [key])?;
    } else {
        conn.execute(
            "INSERT INTO settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
    }
    Ok(())
}

pub fn own_presence_secret(conn: &Connection) -> Result<Option<Vec<u8>>> {
    Ok(match setting(conn, "own_presence_secret")? {
        Value::Blob(bytes) => Some(bytes),
        _ => None,
    })
}

pub fn set_own_presence_secret(conn: &Connection, secret: Option<&[u8]>) -> Result<()> {
    set_setting(conn, "own_presence_secret", secret.map_or(Value::Null, |s| Value::Blob(s.to_vec())))
}
