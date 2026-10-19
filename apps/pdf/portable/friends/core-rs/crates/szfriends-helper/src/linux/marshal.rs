//! D-Bus marshalling (the specification's "Marshaling (Wire Format)"): values in, bytes out, and back, for the types
//! the helper's calls and signals carry. Byte arrays are kept whole ([`Value::Bytes`]) and wiped when dropped, since
//! one carries the identity secret.

use zeroize::Zeroizing;

/// Nesting deeper than this is refused rather than followed.
const DEPTH_MAX: usize = 32;

#[derive(Clone, PartialEq)]
pub enum Value {
    Byte(u8),
    Bool(bool),
    U16(u16),
    I32(i32),
    U32(u32),
    /// `x`, `t` and `d`, kept as their 64 bits.
    U64(u64),
    Str(String),
    ObjectPath(String),
    Signature(String),
    Variant(Box<Value>),
    /// An array of anything but bytes: the element signature, then the elements.
    Array(String, Vec<Value>),
    /// `ay`.
    Bytes(Zeroizing<Vec<u8>>),
    Struct(Vec<Value>),
    DictEntry(Box<Value>, Box<Value>),
}

impl std::fmt::Debug for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // Never the bytes: one of these is the identity secret.
            Self::Bytes(bytes) => write!(f, "Bytes({} bytes)", bytes.len()),
            Self::Str(text) | Self::ObjectPath(text) | Self::Signature(text) => write!(f, "{text:?}"),
            Self::Variant(inner) => write!(f, "Variant({inner:?})"),
            Self::Array(_, items) | Self::Struct(items) => f.debug_list().entries(items).finish(),
            Self::DictEntry(key, value) => write!(f, "{key:?}: {value:?}"),
            Self::Byte(n) => write!(f, "{n}"),
            Self::Bool(b) => write!(f, "{b}"),
            Self::U16(n) => write!(f, "{n}"),
            Self::I32(n) => write!(f, "{n}"),
            Self::U32(n) => write!(f, "{n}"),
            Self::U64(n) => write!(f, "{n}"),
        }
    }
}

impl Value {
    pub fn signature(&self) -> String {
        match self {
            Self::Byte(_) => "y".into(),
            Self::Bool(_) => "b".into(),
            Self::U16(_) => "q".into(),
            Self::I32(_) => "i".into(),
            Self::U32(_) => "u".into(),
            Self::U64(_) => "t".into(),
            Self::Str(_) => "s".into(),
            Self::ObjectPath(_) => "o".into(),
            Self::Signature(_) => "g".into(),
            Self::Variant(_) => "v".into(),
            Self::Array(element, _) => format!("a{element}"),
            Self::Bytes(_) => "ay".into(),
            Self::Struct(fields) => format!("({})", fields.iter().map(Value::signature).collect::<String>()),
            Self::DictEntry(key, value) => format!("{{{}{}}}", key.signature(), value.signature()),
        }
    }

    /// A string dictionary `a{ss}`.
    pub fn string_dict(pairs: &[(&str, &str)]) -> Self {
        let entries = pairs
            .iter()
            .map(|(k, v)| Self::DictEntry(Box::new(Self::Str((*k).into())), Box::new(Self::Str((*v).into()))))
            .collect();
        Self::Array("{ss}".into(), entries)
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::Str(text) | Self::ObjectPath(text) | Self::Signature(text) => Some(text),
            _ => None,
        }
    }
}

fn alignment(signature: &str) -> usize {
    match signature.as_bytes().first() {
        Some(b'y' | b'g' | b'v') => 1,
        Some(b'n' | b'q') => 2,
        Some(b'(' | b'{' | b'x' | b't' | b'd') => 8,
        _ => 4,
    }
}

/// Builds a byte stream whose alignment counts from its own start (a body, or a whole header).
#[derive(Default)]
pub struct Encoder {
    bytes: Zeroizing<Vec<u8>>,
}

impl std::fmt::Debug for Encoder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Encoder({} bytes)", self.bytes.len())
    }
}

impl Encoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn align(&mut self, to: usize) {
        while self.bytes.len() % to != 0 {
            self.bytes.push(0);
        }
    }

    fn u32(&mut self, n: u32) {
        self.align(4);
        self.bytes.extend_from_slice(&n.to_le_bytes());
    }

    pub fn value(&mut self, value: &Value) {
        match value {
            Value::Byte(b) => self.bytes.push(*b),
            Value::Bool(b) => self.u32(u32::from(*b)),
            Value::U16(n) => {
                self.align(2);
                self.bytes.extend_from_slice(&n.to_le_bytes());
            }
            Value::I32(n) => self.u32(*n as u32),
            Value::U32(n) => self.u32(*n),
            Value::U64(n) => {
                self.align(8);
                self.bytes.extend_from_slice(&n.to_le_bytes());
            }
            Value::Str(text) | Value::ObjectPath(text) => {
                self.u32(text.len() as u32);
                self.bytes.extend_from_slice(text.as_bytes());
                self.bytes.push(0);
            }
            Value::Signature(text) => {
                self.bytes.push(text.len() as u8);
                self.bytes.extend_from_slice(text.as_bytes());
                self.bytes.push(0);
            }
            Value::Variant(inner) => {
                self.value(&Value::Signature(inner.signature()));
                self.value(inner);
            }
            Value::Bytes(bytes) => {
                self.u32(bytes.len() as u32);
                self.bytes.extend_from_slice(bytes);
            }
            Value::Array(element, items) => {
                self.u32(0);
                let length_at = self.bytes.len() - 4;
                self.align(alignment(element));
                let start = self.bytes.len();
                for item in items {
                    self.value(item);
                }
                let length = (self.bytes.len() - start) as u32;
                self.bytes[length_at..length_at + 4].copy_from_slice(&length.to_le_bytes());
            }
            Value::Struct(fields) => {
                self.align(8);
                for field in fields {
                    self.value(field);
                }
            }
            Value::DictEntry(key, value) => {
                self.align(8);
                self.value(key);
                self.value(value);
            }
        }
    }

    pub fn finish(self) -> Zeroizing<Vec<u8>> {
        self.bytes
    }
}

/// The length of the first complete type in `signature`.
fn complete_type(signature: &str, depth: usize) -> Option<usize> {
    if depth > DEPTH_MAX {
        return None;
    }
    let bytes = signature.as_bytes();
    match bytes.first()? {
        b'a' => Some(1 + complete_type(&signature[1..], depth + 1)?),
        open @ (b'(' | b'{') => {
            let close = if *open == b'(' { b')' } else { b'}' };
            let mut at = 1;
            while *bytes.get(at)? != close {
                at += complete_type(&signature[at..], depth + 1)?;
            }
            Some(at + 1)
        }
        b'y' | b'b' | b'n' | b'q' | b'i' | b'u' | b'h' | b'x' | b't' | b'd' | b's' | b'o' | b'g' | b'v' => Some(1),
        _ => None,
    }
}

/// The complete types a signature lists, in order.
pub fn split(signature: &str) -> Option<Vec<&str>> {
    let mut types = Vec::new();
    let mut rest = signature;
    while !rest.is_empty() {
        let length = complete_type(rest, 0)?;
        types.push(&rest[..length]);
        rest = &rest[length..];
    }
    Some(types)
}

/// Reads values from bytes whose alignment counts from the start of `bytes`.
pub struct Decoder<'a> {
    bytes: &'a [u8],
    at: usize,
    big: bool,
    depth: usize,
}

impl std::fmt::Debug for Decoder<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Decoder(at {} of {} bytes)", self.at, self.bytes.len())
    }
}

impl<'a> Decoder<'a> {
    pub fn new(bytes: &'a [u8], big: bool, at: usize) -> Self {
        Self { bytes, at, big, depth: 0 }
    }

    fn align(&mut self, to: usize) -> Option<()> {
        self.at = self.at.div_ceil(to) * to;
        (self.at <= self.bytes.len()).then_some(())
    }

    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let slice = self.bytes.get(self.at..self.at.checked_add(n)?)?;
        self.at += n;
        Some(slice)
    }

    fn u32(&mut self) -> Option<u32> {
        self.align(4)?;
        let b: [u8; 4] = self.take(4)?.try_into().ok()?;
        Some(if self.big { u32::from_be_bytes(b) } else { u32::from_le_bytes(b) })
    }

    fn text(&mut self, length: usize) -> Option<String> {
        let bytes = self.take(length + 1)?;
        let (text, nul) = bytes.split_at(length);
        (nul == [0]).then(|| std::str::from_utf8(text).ok().map(str::to_owned)).flatten()
    }

    pub fn values(&mut self, signature: &str) -> Option<Vec<Value>> {
        split(signature)?.into_iter().map(|t| self.value(t)).collect()
    }

    /// One value of the complete type `signature`.
    pub fn value(&mut self, signature: &str) -> Option<Value> {
        self.depth += 1;
        let value = if self.depth > DEPTH_MAX { None } else { self.value_inner(signature) };
        self.depth -= 1;
        value
    }

    fn value_inner(&mut self, signature: &str) -> Option<Value> {
        Some(match signature.as_bytes().first()? {
            b'y' => Value::Byte(self.take(1)?[0]),
            b'b' => match self.u32()? {
                0 => Value::Bool(false),
                1 => Value::Bool(true),
                _ => return None,
            },
            b'n' | b'q' => {
                self.align(2)?;
                let b: [u8; 2] = self.take(2)?.try_into().ok()?;
                Value::U16(if self.big { u16::from_be_bytes(b) } else { u16::from_le_bytes(b) })
            }
            b'i' => Value::I32(self.u32()? as i32),
            b'u' | b'h' => Value::U32(self.u32()?),
            b'x' | b't' | b'd' => {
                self.align(8)?;
                let b: [u8; 8] = self.take(8)?.try_into().ok()?;
                Value::U64(if self.big { u64::from_be_bytes(b) } else { u64::from_le_bytes(b) })
            }
            b's' => {
                let length = self.u32()? as usize;
                Value::Str(self.text(length)?)
            }
            b'o' => {
                let length = self.u32()? as usize;
                Value::ObjectPath(self.text(length)?)
            }
            b'g' => {
                let length = usize::from(self.take(1)?[0]);
                Value::Signature(self.text(length)?)
            }
            b'v' => {
                let length = usize::from(self.take(1)?[0]);
                let inner = self.text(length)?;
                if complete_type(&inner, 0)? != inner.len() {
                    return None;
                }
                Value::Variant(Box::new(self.value(&inner)?))
            }
            b'a' => {
                let length = self.u32()? as usize;
                let element = &signature[1..];
                self.align(alignment(element))?;
                if element == "y" {
                    return Some(Value::Bytes(Zeroizing::new(self.take(length)?.to_vec())));
                }
                let end = self.at.checked_add(length).filter(|&e| e <= self.bytes.len())?;
                let mut items = Vec::new();
                while self.at < end {
                    items.push(self.value(element)?);
                }
                if self.at != end {
                    return None;
                }
                Value::Array(element.to_owned(), items)
            }
            b'(' => {
                self.align(8)?;
                Value::Struct(self.values(&signature[1..signature.len() - 1])?)
            }
            b'{' => {
                self.align(8)?;
                let mut pair = self.values(&signature[1..signature.len() - 1])?.into_iter();
                let (key, value) = (pair.next()?, pair.next()?);
                Value::DictEntry(Box::new(key), Box::new(value))
            }
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(value: Value) {
        let mut encoder = Encoder::new();
        encoder.value(&value);
        let bytes = encoder.finish();
        let signature = value.signature();
        assert_eq!(Decoder::new(&bytes, false, 0).value(&signature), Some(value), "{signature}");
    }

    #[test]
    fn every_type_the_helper_uses_round_trips() {
        round_trip(Value::string_dict(&[("application", "shenzhen-friends"), ("szfriends-name", "identity")]));
        round_trip(Value::Struct(vec![
            Value::ObjectPath("/org/freedesktop/secrets/session/s1".into()),
            Value::Bytes(Zeroizing::new(vec![])),
            Value::Bytes(Zeroizing::new(vec![1, 2, 3, 4, 5])),
            Value::Str("application/octet-stream".into()),
        ]));
        round_trip(Value::Array(
            "{sv}".into(),
            vec![Value::DictEntry(
                Box::new(Value::Str("org.freedesktop.Secret.Item.Label".into())),
                Box::new(Value::Variant(Box::new(Value::Str("Shenzhen Friends".into())))),
            )],
        ));
        round_trip(Value::Array("o".into(), vec![]));
        round_trip(Value::Struct(vec![Value::Byte(7), Value::Bool(true), Value::U64(9), Value::U16(3)]));
        assert_eq!(split("a{sv}(oayays)bo"), Some(vec!["a{sv}", "(oayays)", "b", "o"]));
        assert_eq!(split("a"), None);
        assert_eq!(split("(ss"), None);
    }

    #[test]
    fn hostile_input_is_refused_not_followed() {
        let deep = format!("{}y", "a".repeat(64));
        assert_eq!(split(&deep), None);
        let mut length_past_end = vec![0xff, 0xff, 0, 0];
        length_past_end.extend_from_slice(b"short");
        assert_eq!(Decoder::new(&length_past_end, false, 0).value("s"), None);
        assert_eq!(Decoder::new(&[2, 0, 0, 0], false, 0).value("b"), None);
        assert_eq!(Decoder::new(&[1, b'z', 0], false, 0).value("v"), None);
        let secret = format!("{:?}", Value::Bytes(Zeroizing::new(vec![0x42; 133])));
        assert_eq!(secret, "Bytes(133 bytes)", "Debug never shows the bytes");
    }
}
