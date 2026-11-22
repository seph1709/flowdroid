//! HTTP Request: the core describes each request as an effect; the host sends
//! them and returns one response per item:
//! `{ responses: [{ status, headers, body } | { error }] }`.

use super::file_refs::{file_path, mime_from_path};
use super::integrations::api::credential_param;
use super::spec::{Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::expression::render;
use crate::json::parse_json;
use crate::value::{Obj, Val, format_number, get_key, obj, stringify, to_num, to_template_str};

const DEFAULT_TIMEOUT_SECONDS: f64 = 30.0;

fn build_request(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let url = run.text("url", index)?;
    if url.is_empty() {
        return fail(ErrorKind::Node, "URL is required");
    }
    let scope = run.scope(index);
    let mut headers = Obj::new();
    for row in run.rows("headers")? {
        let name = to_template_str(&render(get_key(row, "name"), &scope)?);
        if !name.is_empty() {
            let value = to_template_str(&render(get_key(row, "value"), &scope)?);
            headers.insert(name, Val::Str(value));
        }
    }
    let timeout = to_num(&run.value("timeout", index)?);
    let method = run.text("method", index)?.to_uppercase();
    let send_file = file_path(run, "sendFile", index)?;
    let has_type = headers.keys().any(|k| k.to_lowercase() == "content-type");
    if !send_file.is_empty() && !has_type {
        headers.insert(
            "Content-Type".into(),
            Val::Str(mime_from_path(&send_file).into()),
        );
    }
    let body = if send_file.is_empty() {
        request_body(run.value("body", index)?, &mut headers)
    } else {
        Val::Null
    };
    let timeout_seconds = if timeout > 0.0 {
        timeout
    } else {
        DEFAULT_TIMEOUT_SECONDS
    };
    let mut request = obj([
        ("method", Val::Str(method)),
        ("url", Val::Str(url)),
        ("headers", Val::Obj(headers)),
        ("body", body),
        ("timeoutMs", Val::Num(timeout_seconds * 1000.0)),
    ]);
    // The host sends the file's bytes as the body, or saves the response as a file.
    if !send_file.is_empty() {
        request.insert("file".into(), Val::Str(send_file));
    }
    if run.param("responseFormat").is_str("file") {
        request.insert("saveAs".into(), "file".into());
    }
    // The host adds the credential's header (API key, bearer token, basic auth or OAuth2) when sending.
    let credential = run.text("credential", index)?;
    if !credential.is_empty() {
        request.insert("credential".into(), Val::Str(credential));
        request.insert("auth".into(), Val::Bool(true));
    }
    Ok(Val::Obj(request))
}

/// Credential types HTTP Request can authenticate with.
pub const AUTH_CREDENTIALS: &[&str] = &["headerAuth", "bearerAuth", "basicAuth", "oauth2"];

/// Text bodies are sent as is; structured ones as JSON, with a content type unless one is set.
fn request_body(body: Val, headers: &mut Obj) -> Val {
    match body {
        Val::Null => Val::Null,
        Val::Str(s) if s.is_empty() => Val::Null,
        Val::Str(s) => Val::Str(s),
        other => {
            if !headers
                .keys()
                .any(|name| name.to_lowercase() == "content-type")
            {
                headers.insert("Content-Type".into(), "application/json".into());
            }
            Val::Str(stringify(&other))
        }
    }
}

fn to_items(run: &NodeRun<'_>, response: &Val) -> Result<Vec<Item>> {
    let Val::Obj(response) = response else {
        return fail(ErrorKind::Node, "response must be an object");
    };
    if let Val::Str(error) = get_key(response, "error") {
        return fail(ErrorKind::Node, format!("request failed: {error}"));
    }
    let status = to_num(get_key(response, "status"));
    if status >= 400.0 && !run.param("ignoreHttpErrors").is_true() {
        return fail(
            ErrorKind::Node,
            format!("request failed with status {}", format_number(status)),
        );
    }
    let text = to_template_str(get_key(response, "body"));
    if run.param("responseFormat").is_str("file") {
        // The host saved the bytes and answers with the file's reference.
        let file = match parse_or_text(text) {
            v @ Val::Obj(_) => v,
            _ => Val::Null,
        };
        if run.param("fullResponse").is_true() {
            let headers = get_key(response, "headers")
                .as_obj()
                .cloned()
                .unwrap_or_default();
            return Ok(vec![obj([
                ("statusCode", Val::Num(status)),
                ("headers", Val::Obj(headers)),
                ("file", file),
            ])]);
        }
        return Ok(vec![obj([("file", file)])]);
    }
    let body = if run.param("responseFormat").is_str("text") {
        Val::Str(text)
    } else {
        parse_or_text(text)
    };
    if run.param("fullResponse").is_true() {
        let headers = get_key(response, "headers")
            .as_obj()
            .cloned()
            .unwrap_or_default();
        return Ok(vec![obj([
            ("statusCode", Val::Num(status)),
            ("headers", Val::Obj(headers)),
            ("body", body),
        ])]);
    }
    Ok(match body {
        Val::Arr(list) => list.into_iter().map(as_item).collect(),
        other => vec![as_item(other)],
    })
}

fn as_item(v: Val) -> Item {
    match v {
        Val::Obj(o) => o,
        other => obj([("data", other)]),
    }
}

fn parse_or_text(text: String) -> Val {
    parse_json(&text, "response body", ErrorKind::Input).unwrap_or(Val::Str(text))
}

fn run_request(run: &NodeRun<'_>) -> Result<NodeResult> {
    let requests = (0..run.items().len())
        .map(|i| build_request(run, i))
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "http".into()),
        ("requests", Val::Arr(requests)),
    ])))
}

fn resume_request(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    let items = run.items();
    let responses = match get_key(result, "responses") {
        Val::Arr(list) if list.len() == items.len() => list,
        _ => {
            return fail(
                ErrorKind::Node,
                format!("expected {} responses", items.len()),
            );
        }
    };
    let mut out = Vec::new();
    for response in responses {
        out.extend(to_items(run, response)?);
    }
    Ok(vec![out])
}

pub static HTTP_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "http.request",
    label: "HTTP Request",
    group: NodeGroup::Network,
    description: "Calls a URL once per item and outputs the response.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        ParamSpec::new("method", "Method", ParamKind::Select, Default::Text("GET"))
            .options(&["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]),
        ParamSpec {
            label: "Authentication",
            hint: Some("empty = none"),
            ..credential_param(AUTH_CREDENTIALS)
        },
        ParamSpec::new("url", "URL", ParamKind::Text, Default::Text(""))
            .hint("https://api.example.com/{{ $json.id }}"),
        ParamSpec::new(
            "headers",
            "Headers",
            ParamKind::KeyValues,
            Default::EmptyList,
        ),
        ParamSpec::new("body", "Body", ParamKind::Json, Default::Text("")),
        ParamSpec::new(
            "sendFile",
            "Send a file as the body",
            ParamKind::Text,
            Default::Text(""),
        )
        .hint("e.g. {{ $json.file.path }}; replaces Body"),
        ParamSpec::new(
            "responseFormat",
            "Response format",
            ParamKind::Select,
            Default::Text("json"),
        )
        .options(&["json", "text", "file"]),
        ParamSpec::new(
            "fullResponse",
            "Include status and headers",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
        ParamSpec::new(
            "ignoreHttpErrors",
            "Continue on 4xx/5xx",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
        ParamSpec::new(
            "timeout",
            "Timeout (seconds)",
            ParamKind::Number,
            Default::Number(DEFAULT_TIMEOUT_SECONDS),
        ),
    ],
    run: run_request,
    resume: Some(resume_request),
    step: None,
}];
