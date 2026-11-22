use crate::errors::{ErrorKind, Result, fail};

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Num(f64),
    Str(String),
    Ident(String),
    Op(&'static str),
    End,
}

/// Longest operators first so `===` wins over `==`.
const OPERATORS: [&str; 25] = [
    "===", "!==", "==", "!=", "<=", ">=", "&&", "||", "??", "<", ">", "+", "-", "*", "/", "%", "!",
    "?", ":", ".", ",", "(", ")", "[", "]",
];

fn is_ident_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_' || c == '$'
}

fn is_ident_part(c: char) -> bool {
    is_ident_start(c) || c.is_ascii_digit()
}

pub fn tokenize(src: &str) -> Result<Vec<Token>> {
    let mut tokens = Vec::new();
    let mut i = 0;
    while let Some(c) = src[i..].chars().next() {
        if matches!(c, ' ' | '\t' | '\n' | '\r') {
            i += 1;
        } else if c.is_ascii_digit() {
            i = read_number(src, i, &mut tokens);
        } else if c == '"' || c == '\'' {
            i = read_string(src, i, &mut tokens)?;
        } else if is_ident_start(c) {
            let end = src[i..]
                .find(|c| !is_ident_part(c))
                .map_or(src.len(), |n| i + n);
            tokens.push(Token::Ident(src[i..end].to_owned()));
            i = end;
        } else {
            let Some(op) = OPERATORS.iter().find(|op| src[i..].starts_with(*op)) else {
                return fail(ErrorKind::Expression, "unexpected character");
            };
            tokens.push(Token::Op(op));
            i += op.len();
        }
    }
    tokens.push(Token::End);
    Ok(tokens)
}

fn read_number(src: &str, start: usize, tokens: &mut Vec<Token>) -> usize {
    let b = src.as_bytes();
    let skip_digits = |mut j: usize| {
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        j
    };
    let mut end = skip_digits(start);
    if b.get(end) == Some(&b'.') && b.get(end + 1).is_some_and(u8::is_ascii_digit) {
        end = skip_digits(end + 1);
    }
    tokens.push(Token::Num(src[start..end].parse().unwrap_or(f64::NAN)));
    end
}

fn read_string(src: &str, start: usize, tokens: &mut Vec<Token>) -> Result<usize> {
    let mut chars = src[start..].char_indices();
    let quote = chars.next().map(|(_, q)| q);
    let mut out = String::new();
    while let Some((offset, c)) = chars.next() {
        if Some(c) == quote {
            tokens.push(Token::Str(out));
            return Ok(start + offset + 1);
        }
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some((_, e)) => out.push(match e {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => '\u{8}',
                'f' => '\u{c}',
                'v' => '\u{b}',
                '0' => '\0',
                other => other,
            }),
            None => out.push('\\'),
        }
    }
    fail(ErrorKind::Expression, "unterminated string")
}
