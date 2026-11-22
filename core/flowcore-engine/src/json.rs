//! JSON parsing with JavaScript's `JSON.parse` semantics (numbers as `f64`,
//! later duplicate keys win, `1e400` is `Infinity`).
//!
//! Parsing runs in three steps so no input can overflow the stack: tokenize,
//! check the grammar and nesting depth with an explicit stack, then build the
//! value recursively, which is safe because depth is bounded by then.

use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val};

/// Deeper documents are rejected (matches `MAX_DEPTH` in `json.ts`).
pub const MAX_DEPTH: usize = 64;

#[derive(Debug, Clone)]
enum Token {
    Open(u8),
    Close(u8),
    Colon,
    Comma,
    Scalar(Val),
}

/// Parses untrusted JSON; `what` names the argument in error messages.
pub fn parse_json(text: &str, what: &str, kind: ErrorKind) -> Result<Val> {
    let invalid = || fail(kind, format!("{what} is not valid JSON"));
    let Some(tokens) = tokenize(text) else {
        return invalid();
    };
    let Some(depth) = check(&tokens) else {
        return invalid();
    };
    if depth > MAX_DEPTH {
        return fail(kind, format!("{what} is nested too deeply"));
    }
    let mut pos = 0;
    Ok(build(&tokens, &mut pos))
}

fn tokenize(text: &str) -> Option<Vec<Token>> {
    let bytes = text.as_bytes();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let token = match bytes[i] {
            b' ' | b'\t' | b'\n' | b'\r' => {
                i += 1;
                continue;
            }
            b @ (b'{' | b'[') => Token::Open(b),
            b @ (b'}' | b']') => Token::Close(b),
            b':' => Token::Colon,
            b',' => Token::Comma,
            b'"' => {
                let (s, next) = read_string(text, i + 1)?;
                i = next;
                tokens.push(Token::Scalar(Val::Str(s)));
                continue;
            }
            b'-' | b'0'..=b'9' => {
                let end = number_end(bytes, i)?;
                tokens.push(Token::Scalar(Val::Num(text[i..end].parse().ok()?)));
                i = end;
                continue;
            }
            _ => {
                let (word, val) = [
                    ("true", Val::Bool(true)),
                    ("false", Val::Bool(false)),
                    ("null", Val::Null),
                ]
                .into_iter()
                .find(|(w, _)| text[i..].starts_with(w))?;
                i += word.len();
                tokens.push(Token::Scalar(val));
                continue;
            }
        };
        tokens.push(token);
        i += 1;
    }
    Some(tokens)
}

/// End of a JSON number starting at `start`: `-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`.
fn number_end(b: &[u8], start: usize) -> Option<usize> {
    let mut i = start;
    let digits = |i: &mut usize| {
        let s = *i;
        while *i < b.len() && b[*i].is_ascii_digit() {
            *i += 1;
        }
        *i - s
    };
    if b.get(i) == Some(&b'-') {
        i += 1;
    }
    match b.get(i) {
        Some(b'0') => i += 1,
        Some(b'1'..=b'9') => {
            digits(&mut i);
        }
        _ => return None,
    }
    if b.get(i) == Some(&b'.') {
        i += 1;
        if digits(&mut i) == 0 {
            return None;
        }
    }
    if matches!(b.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(b.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        if digits(&mut i) == 0 {
            return None;
        }
    }
    Some(i)
}

/// Decodes a string body starting after the opening quote; returns it and the index after the closing quote.
fn read_string(text: &str, start: usize) -> Option<(String, usize)> {
    let mut out = String::new();
    let mut chars = text[start..].char_indices();
    while let Some((offset, c)) = chars.next() {
        match c {
            '"' => return Some((out, start + offset + 1)),
            '\\' => match chars.next()?.1 {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                'b' => out.push('\u{8}'),
                'f' => out.push('\u{c}'),
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'u' => {
                    let unit = read_hex4(&mut chars)?;
                    out.push(decode_unit(unit, &mut chars)?);
                }
                _ => return None,
            },
            c if (c as u32) < 0x20 => return None,
            c => out.push(c),
        }
    }
    None
}

fn read_hex4(chars: &mut std::str::CharIndices<'_>) -> Option<u16> {
    let mut unit = 0u16;
    for _ in 0..4 {
        unit = unit * 16 + chars.next()?.1.to_digit(16)? as u16;
    }
    Some(unit)
}

/// Joins a surrogate pair written as two escapes. A lone surrogate, which a
/// Rust string cannot hold, becomes U+FFFD.
fn decode_unit(unit: u16, chars: &mut std::str::CharIndices<'_>) -> Option<char> {
    if !(0xD800..0xDC00).contains(&unit) {
        return Some(char::from_u32(u32::from(unit)).unwrap_or(char::REPLACEMENT_CHARACTER));
    }
    let mut lookahead = chars.clone();
    if lookahead.next().map(|(_, c)| c) == Some('\\')
        && lookahead.next().map(|(_, c)| c) == Some('u')
    {
        if let Some(low) = read_hex4(&mut lookahead).filter(|u| (0xDC00..0xE000).contains(u)) {
            *chars = lookahead;
            let code = 0x10000 + ((u32::from(unit) - 0xD800) << 10) + (u32::from(low) - 0xDC00);
            return char::from_u32(code);
        }
    }
    Some(char::REPLACEMENT_CHARACTER)
}

#[derive(Clone, Copy, PartialEq)]
enum Expect {
    Value,
    ValueOrClose,
    KeyOrClose,
    Key,
    Colon,
    CommaOrClose,
    End,
}

/// Checks the grammar without recursion; returns the deepest value level (root is 0).
fn check(tokens: &[Token]) -> Option<usize> {
    let mut stack: Vec<u8> = Vec::new();
    let mut state = Expect::Value;
    let mut max_depth = 0;
    for token in tokens {
        state = match (state, token) {
            (Expect::Value | Expect::ValueOrClose, Token::Scalar(_)) => {
                max_depth = max_depth.max(stack.len());
                after_value(&stack)
            }
            (Expect::Value | Expect::ValueOrClose, Token::Open(kind)) => {
                max_depth = max_depth.max(stack.len());
                stack.push(*kind);
                if *kind == b'[' {
                    Expect::ValueOrClose
                } else {
                    Expect::KeyOrClose
                }
            }
            (Expect::ValueOrClose, Token::Close(b']'))
            | (Expect::KeyOrClose, Token::Close(b'}')) => {
                stack.pop();
                after_value(&stack)
            }
            (Expect::KeyOrClose | Expect::Key, Token::Scalar(Val::Str(_))) => Expect::Colon,
            (Expect::Colon, Token::Colon) => Expect::Value,
            (Expect::CommaOrClose, Token::Comma) => {
                if stack.last() == Some(&b'[') {
                    Expect::Value
                } else {
                    Expect::Key
                }
            }
            (Expect::CommaOrClose, Token::Close(close)) => {
                let open = if *close == b']' { b'[' } else { b'{' };
                if stack.pop() != Some(open) {
                    return None;
                }
                after_value(&stack)
            }
            _ => return None,
        };
    }
    (state == Expect::End).then_some(max_depth)
}

fn after_value(stack: &[u8]) -> Expect {
    if stack.is_empty() {
        Expect::End
    } else {
        Expect::CommaOrClose
    }
}

/// Builds a value from tokens already checked by [`check`].
fn build(tokens: &[Token], pos: &mut usize) -> Val {
    let token = tokens.get(*pos).cloned();
    *pos += 1;
    match token {
        Some(Token::Scalar(v)) => v,
        Some(Token::Open(b'[')) => {
            let mut items = Vec::new();
            while !matches!(tokens.get(*pos), Some(Token::Close(_)) | None) {
                items.push(build(tokens, pos));
                if matches!(tokens.get(*pos), Some(Token::Comma)) {
                    *pos += 1;
                }
            }
            *pos += 1;
            Val::Arr(items)
        }
        Some(Token::Open(_)) => {
            let mut o = Obj::new();
            while let Some(Token::Scalar(Val::Str(key))) = tokens.get(*pos).cloned() {
                *pos += 2; // key and colon
                let value = build(tokens, pos);
                o.insert(key, value);
                if matches!(tokens.get(*pos), Some(Token::Comma)) {
                    *pos += 1;
                }
            }
            *pos += 1;
            Val::Obj(o)
        }
        // INFALLIBLE: `check` accepted the token stream, so nothing else starts a value.
        _ => Val::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::value::stringify;

    fn parse(s: &str) -> Result<String> {
        parse_json(s, "doc", ErrorKind::Input).map(|v| stringify(&v))
    }

    #[test]
    fn parses_like_json_parse() {
        assert_eq!(
            parse(r#" {"a":[1,-0,2.5e1,true,null],"a":"x"} "#).unwrap(),
            r#"{"a":"x"}"#
        );
        assert_eq!(parse(r#""😀 é""#).unwrap(), "\"\u{1F600} \u{e9}\"");
        assert_eq!(parse("1e400").unwrap(), "null");
    }

    #[test]
    fn rejects_bad_documents() {
        for bad in [
            "", "01", "1.", "[1,]", "{\"a\"}", "{1:2}", "[1 2]", "nul", "\"\t\"", "[}", "1 1",
        ] {
            assert_eq!(
                parse(bad).unwrap_err().to_string(),
                "InputError: doc is not valid JSON",
                "{bad}"
            );
        }
    }

    #[test]
    fn bounds_depth_without_recursion() {
        let deep = format!("{}{}", "[".repeat(100_000), "]".repeat(100_000));
        assert_eq!(
            parse(&deep).unwrap_err().to_string(),
            "InputError: doc is nested too deeply"
        );
        let too_deep = format!("{}1{}", "[".repeat(65), "]".repeat(65));
        assert_eq!(
            parse(&too_deep).unwrap_err().to_string(),
            "InputError: doc is nested too deeply"
        );
        for ok in [
            format!("{}1{}", "[".repeat(64), "]".repeat(64)),
            format!("{}{}", "[".repeat(65), "]".repeat(65)),
        ] {
            assert!(parse(&ok).is_ok());
        }
    }
}
