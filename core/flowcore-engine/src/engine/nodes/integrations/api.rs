//! Shared plumbing for nodes that call a third-party API; see `integrations/api.ts`.
//!
//! Requests name a stored credential instead of carrying secrets; the host
//! fills `{cred:field}` placeholders, so keys never enter the engine.

use std::fmt::Write as _;

use super::super::spec::{Default, NodeResult, NodeRun, ParamKind, ParamSpec};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{
    Obj, Val, format_number, get_key, obj, stringify, to_num, to_str, to_template_str,
};

pub const DEFAULT_API_TIMEOUT_MS: f64 = 60_000.0;

#[must_use]
pub const fn credential_param(types: &'static [&'static str]) -> ParamSpec {
    ParamSpec::new(
        "credential",
        "Credential",
        ParamKind::Credential,
        Default::Text(""),
    )
    .options(types)
}

/// One call to describe; `body: None` sends no body.
pub struct ApiCall {
    pub method: &'static str,
    pub url: String,
    pub headers: Obj,
    pub body: Option<Val>,
    pub timeout_ms: f64,
}

impl ApiCall {
    pub fn new(method: &'static str, url: impl Into<String>) -> Self {
        Self {
            method,
            url: url.into(),
            headers: Obj::new(),
            body: None,
            timeout_ms: DEFAULT_API_TIMEOUT_MS,
        }
    }

    #[must_use]
    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.insert(name.to_owned(), Val::from(value));
        self
    }

    #[must_use]
    pub fn body(mut self, body: Val) -> Self {
        self.body = Some(body);
        self
    }

    #[must_use]
    pub fn timeout(mut self, ms: f64) -> Self {
        self.timeout_ms = ms;
        self
    }
}

/// The credential the node is set to use; every API node needs one.
pub fn credential_name(run: &NodeRun<'_>) -> Result<String> {
    let name = run.text("credential", 0)?;
    if name.is_empty() {
        return fail(ErrorKind::Node, "choose a credential");
    }
    Ok(name)
}

/// One request of an `http` effect, carrying the credential name for the host.
pub fn api_request(run: &NodeRun<'_>, call: ApiCall) -> Result<Val> {
    let mut headers = call.headers;
    let body = match call.body {
        None | Some(Val::Null) => Val::Null,
        Some(Val::Str(s)) => Val::Str(s),
        Some(other) => {
            headers.insert("Content-Type".into(), "application/json".into());
            Val::Str(stringify(&other))
        }
    };
    Ok(Val::Obj(obj([
        ("method", call.method.into()),
        ("url", Val::Str(call.url)),
        ("headers", Val::Obj(headers)),
        ("body", body),
        ("timeoutMs", Val::Num(call.timeout_ms)),
        ("credential", Val::Str(credential_name(run)?)),
    ])))
}

/// [request] (an object) with one more field, for host-side extras like files.
#[must_use]
pub fn with_extra(request: Val, key: &str, value: Val) -> Val {
    match request {
        Val::Obj(mut o) => {
            o.insert(key.into(), value);
            Val::Obj(o)
        }
        other => other,
    }
}

#[must_use]
pub fn api_effect(requests: Vec<Val>) -> NodeResult {
    NodeResult::Effect(obj([
        ("type", "http".into()),
        ("requests", Val::Arr(requests)),
    ]))
}

/// One request per input item.
pub fn per_item(run: &NodeRun<'_>, build: impl Fn(usize) -> Result<Val>) -> Result<NodeResult> {
    let requests = (0..run.items().len())
        .map(build)
        .collect::<Result<Vec<_>>>()?;
    Ok(api_effect(requests))
}

/// Turns the host's responses into items; [map] receives each parsed body and its request index.
pub fn api_resume(
    result: &Obj,
    service: &str,
    mut map: impl FnMut(Val, usize) -> Result<Vec<Item>>,
) -> Result<Vec<Vec<Item>>> {
    let Val::Arr(responses) = get_key(result, "responses") else {
        return fail(ErrorKind::Node, format!("{service} returned no response"));
    };
    let mut out = Vec::new();
    for (i, response) in responses.iter().enumerate() {
        out.extend(map(check_response(service, response)?, i)?);
    }
    Ok(vec![out])
}

/// The parsed body of a successful response; fails with the service's own message otherwise.
pub fn check_response(service: &str, response: &Val) -> Result<Val> {
    let Val::Obj(response) = response else {
        return fail(ErrorKind::Node, format!("{service} returned no response"));
    };
    if let Val::Str(error) = get_key(response, "error") {
        return fail(
            ErrorKind::Node,
            format!("{service} request failed: {error}"),
        );
    }
    let status = to_num(get_key(response, "status"));
    let body = parse_or_text(to_template_str(get_key(response, "body")));
    if status >= 400.0 {
        return fail(
            ErrorKind::Node,
            format!(
                "{service} error {}: {}",
                format_number(status),
                error_message(&body)
            ),
        );
    }
    Ok(body)
}

#[must_use]
pub fn parse_or_text(text: String) -> Val {
    parse_json(&text, "response body", ErrorKind::Input).unwrap_or(Val::Str(text))
}

/// The most useful message in an API error body.
fn error_message(body: &Val) -> String {
    if let Val::Obj(o) = body {
        let error = get_key(o, "error");
        if let Val::Obj(e) = error {
            if let Val::Str(message) = get_key(e, "message") {
                return message.clone();
            }
        }
        for key in ["message", "description", "error_description"] {
            if let Val::Str(message) = get_key(o, key) {
                return message.clone();
            }
        }
        if let Val::Str(e) = error {
            return e.clone();
        }
    }
    let text = to_str(body);
    if text.chars().count() > 200 {
        format!("{}…", text.chars().take(200).collect::<String>())
    } else {
        text
    }
}

/// A body as items: lists give one item per entry, objects one item, anything else `{data}`.
#[must_use]
pub fn as_items(v: Val) -> Vec<Item> {
    let one = |x: Val| match x {
        Val::Obj(o) => o,
        other => obj([("data", other)]),
    };
    match v {
        Val::Arr(list) => list.into_iter().map(one).collect(),
        other => vec![one(other)],
    }
}

/// JavaScript's `encodeURIComponent`.
#[must_use]
pub fn enc(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
            out.push(char::from(b));
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

const B64_STANDARD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64_URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64(text: &str, alphabet: &[u8; 64], pad: bool) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(bytes.len() * 4 / 3 + 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        let chars = (chunk.len() * 8).div_ceil(6).min(4);
        for k in 0..chars {
            out.push(char::from(alphabet[((n >> (18 - 6 * k)) & 63) as usize]));
        }
        if pad {
            out.push_str(&"=".repeat(4 - chars));
        }
    }
    out
}

/// URL-safe base64 of the UTF-8 bytes, without padding (Gmail's `raw`).
#[must_use]
pub fn base64_url(text: &str) -> String {
    base64(text, B64_URL, false)
}

/// Standard padded base64 of the UTF-8 bytes (email header encoding).
#[must_use]
pub fn base64_standard(text: &str) -> String {
    base64(text, B64_STANDARD, true)
}

/// A text parameter that must not be empty.
pub fn required(run: &NodeRun<'_>, key: &str, index: usize, label: &str) -> Result<String> {
    let v = run.text(key, index)?;
    if v.is_empty() {
        return fail(ErrorKind::Node, format!("{label} is required"));
    }
    Ok(v)
}

/// A JSON parameter: objects and lists as they are; text is parsed as JSON when it is valid JSON.
pub fn json_param(run: &NodeRun<'_>, key: &str, index: usize) -> Result<Val> {
    Ok(match run.value(key, index)? {
        Val::Str(text) => parse_json(&text, key, ErrorKind::Input).unwrap_or(Val::Str(text)),
        other => other,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_like_javascript() {
        assert_eq!(enc("a b&c=d/é~*'()"), "a%20b%26c%3Dd%2F%C3%A9~*'()");
        assert_eq!(base64_url("Héllo"), "SMOpbGxv");
        assert_eq!(base64_standard("ab"), "YWI=");
        assert_eq!(base64_url("ab"), "YWI");
    }
}
