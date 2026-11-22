//! AI chat; see `integrations/ai.ts`.

use super::super::file_refs::{file_marker, file_path, mime_from_path};
use super::super::spec::{Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec};
use super::api::{ApiCall, api_request, api_resume, credential_param, enc, per_item, with_extra};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{Obj, Val, get_key, obj, to_num};

const PROVIDERS: &[&str] = &["anthropic", "openai", "gemini", "openaiCompatible"];
pub const DEFAULT_CLAUDE_MODEL: &str = "claude-opus-5-5";
pub const ANTHROPIC_VERSION: &str = "2026-10-21";
const JSON_INSTRUCTION: &str = "Reply with only valid JSON, no other text.";

fn provider(run: &NodeRun<'_>) -> Result<String> {
    let p = run.text("provider", 0)?;
    if !PROVIDERS.contains(&p.as_str()) {
        return fail(ErrorKind::Node, format!("unknown AI provider {p}"));
    }
    Ok(p)
}

fn model(run: &NodeRun<'_>, index: usize, p: &str) -> Result<String> {
    let m = run.text("model", index)?;
    if !m.is_empty() {
        return Ok(m);
    }
    if p == "anthropic" {
        return Ok(DEFAULT_CLAUDE_MODEL.to_owned());
    }
    fail(ErrorKind::Node, "model is required")
}

fn text_part(prompt: &str) -> Val {
    Val::Obj(obj([
        ("type", "text".into()),
        ("text", Val::Str(prompt.to_owned())),
    ]))
}

/// Claude: the image first, then the question.
fn anthropic_content(prompt: &str, image: &str, mime: &str) -> Val {
    if image.is_empty() {
        return Val::Str(prompt.to_owned());
    }
    Val::Arr(vec![
        Val::Obj(obj([
            ("type", "image".into()),
            (
                "source",
                Val::Obj(obj([
                    ("type", "base64".into()),
                    ("media_type", mime.into()),
                    ("data", Val::Str(file_marker(image))),
                ])),
            ),
        ])),
        text_part(prompt),
    ])
}

fn gemini_parts(prompt: &str, image: &str, mime: &str) -> Val {
    let text = Val::Obj(obj([("text", Val::Str(prompt.to_owned()))]));
    if image.is_empty() {
        return Val::Arr(vec![text]);
    }
    Val::Arr(vec![
        Val::Obj(obj([(
            "inline_data",
            Val::Obj(obj([
                ("mime_type", mime.into()),
                ("data", Val::Str(file_marker(image))),
            ])),
        )])),
        text,
    ])
}

/// `OpenAI` and compatible servers: the question, then the image as a data URL.
fn openai_content(prompt: &str, image: &str, mime: &str) -> Val {
    if image.is_empty() {
        return Val::Str(prompt.to_owned());
    }
    Val::Arr(vec![
        text_part(prompt),
        Val::Obj(obj([
            ("type", "image_url".into()),
            (
                "image_url",
                Val::Obj(obj([(
                    "url",
                    Val::Str(format!("data:{mime};base64,{}", file_marker(image))),
                )])),
            ),
        ])),
    ])
}

/// The image to show the model, if any, with its media type.
fn chat_image(run: &NodeRun<'_>, index: usize) -> Result<(String, &'static str)> {
    let image = file_path(run, "image", index)?;
    if image.is_empty() {
        return Ok((image, ""));
    }
    let mime = mime_from_path(&image);
    if !mime.starts_with("image/") {
        return fail(ErrorKind::Node, format!("{image} is not an image"));
    }
    Ok((image, mime))
}

fn build_chat(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let p = provider(run)?;
    let m = model(run, index, &p)?;
    let prompt = run.text("prompt", index)?;
    if prompt.is_empty() {
        return fail(ErrorKind::Node, "prompt is empty");
    }
    let wants_json = run.param("json").is_true();
    let system = run.text("system", index)?;
    let timeout = to_num(&run.value("timeout", index)?);
    let timeout_ms = (if timeout >= 1.0 { timeout } else { 1.0 }) * 1000.0;
    let (image, mime) = chat_image(run, index)?;
    let user = |content: Val| Val::Obj(obj([("role", "user".into()), ("content", content)]));
    let call = match p.as_str() {
        "anthropic" => {
            let full_system = [
                system.as_str(),
                if wants_json { JSON_INSTRUCTION } else { "" },
            ]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join("\n\n");
            let mut body = obj([("model", Val::Str(m)), ("max_tokens", Val::Num(16000.0))]);
            if !full_system.is_empty() {
                body.insert("system".into(), Val::Str(full_system));
            }
            let content = anthropic_content(&prompt, &image, mime);
            body.insert("messages".into(), Val::Arr(vec![user(content)]));
            // A safety decline re-runs on a fallback model inside the same call.
            body.insert("fallbacks".into(), "default".into());
            ApiCall::new("POST", "https://api.anthropic.com/v1/messages")
                .header("x-api-key", "{cred:apiKey}")
                .header("anthropic-version", ANTHROPIC_VERSION)
                .header("anthropic-beta", "server-side-fallback-2026-07-01")
                .body(Val::Obj(body))
        }
        "gemini" => {
            let part = |text: String| Val::Arr(vec![Val::Obj(obj([("text", Val::Str(text))]))]);
            let parts = gemini_parts(&prompt, &image, mime);
            let mut body = obj([(
                "contents",
                Val::Arr(vec![Val::Obj(obj([
                    ("role", "user".into()),
                    ("parts", parts),
                ]))]),
            )]);
            if !system.is_empty() {
                body.insert(
                    "systemInstruction".into(),
                    Val::Obj(obj([("parts", part(system))])),
                );
            }
            if wants_json {
                body.insert(
                    "generationConfig".into(),
                    Val::Obj(obj([("responseMimeType", "application/json".into())])),
                );
            }
            ApiCall::new(
                "POST",
                format!(
                    "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent",
                    enc(&m)
                ),
            )
            .header("x-goog-api-key", "{cred:apiKey}")
            .body(Val::Obj(body))
        }
        _ => {
            let mut messages = Vec::new();
            if !system.is_empty() {
                messages.push(Val::Obj(obj([
                    ("role", "system".into()),
                    ("content", Val::Str(system)),
                ])));
            }
            let content = openai_content(&prompt, &image, mime);
            messages.push(user(content));
            let mut body = obj([("model", Val::Str(m)), ("messages", Val::Arr(messages))]);
            if wants_json {
                body.insert(
                    "response_format".into(),
                    Val::Obj(obj([("type", "json_object".into())])),
                );
            }
            ApiCall::new(
                "POST",
                "{cred:baseUrl|https://api.openai.com/v1}/chat/completions",
            )
            .header("Authorization", "Bearer {cred:apiKey}")
            .body(Val::Obj(body))
        }
    };
    let request = api_request(run, call.timeout(timeout_ms))?;
    // The host puts the image's bytes where the marker is before sending.
    Ok(if image.is_empty() {
        request
    } else {
        with_extra(request, "inlineFiles", Val::Bool(true))
    })
}

enum Step<'a> {
    Key(&'a str),
    Index(usize),
}

fn at<'a>(v: &'a Val, path: &[Step<'_>]) -> Option<&'a Val> {
    let mut cur = v;
    for step in path {
        cur = match (step, cur) {
            (Step::Key(k), Val::Obj(o)) => o.get(*k)?,
            (Step::Index(i), Val::Arr(a)) => a.get(*i)?,
            _ => return None,
        };
    }
    Some(cur)
}

/// The text of every text part (parts with `type: "text"`, or no type at all), joined.
fn texts(parts: Option<&Val>) -> String {
    let Some(Val::Arr(parts)) = parts else {
        return String::new();
    };
    let mut out = String::new();
    for p in parts {
        let Val::Obj(p) = p else { continue };
        if p.contains_key("type") && !get_key(p, "type").is_str("text") {
            continue;
        }
        if let Val::Str(text) = get_key(p, "text") {
            out.push_str(text);
        }
    }
    out
}

fn reply_text(p: &str, body: &Val) -> Result<String> {
    use Step::{Index, Key};
    Ok(match p {
        "anthropic" => {
            if at(body, &[Key("stop_reason")]).is_some_and(|v| v.is_str("refusal")) {
                let suffix = match at(body, &[Key("stop_details"), Key("category")]) {
                    Some(Val::Str(category)) => format!(" ({category})"),
                    _ => String::new(),
                };
                return fail(
                    ErrorKind::Node,
                    format!("Claude declined this request{suffix}"),
                );
            }
            texts(at(body, &[Key("content")]))
        }
        "gemini" => texts(at(
            body,
            &[Key("candidates"), Index(0), Key("content"), Key("parts")],
        )),
        _ => match at(
            body,
            &[Key("choices"), Index(0), Key("message"), Key("content")],
        ) {
            Some(Val::Str(s)) => s.clone(),
            _ => String::new(),
        },
    })
}

fn resume_chat(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "AI", |body, index| {
        let p = provider(run)?;
        let text = reply_text(&p, &body)?;
        let mut item = obj([
            ("text", Val::Str(text.clone())),
            ("provider", Val::Str(p.clone())),
            ("model", Val::Str(model(run, index, &p)?)),
        ]);
        if run.param("json").is_true() {
            match parse_json(&text, "reply", ErrorKind::Input) {
                Ok(v) => {
                    item.insert("json".into(), v);
                }
                Err(_) => return fail(ErrorKind::Node, "the reply is not valid JSON"),
            }
        }
        Ok(vec![item])
    })
}

fn run_chat(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| build_chat(run, i))
}

pub static AI_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "ai.chat",
    label: "AI Chat",
    group: NodeGroup::Ai,
    description: "Sends a prompt per item to an AI model and outputs its reply.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        ParamSpec::new(
            "provider",
            "Provider",
            ParamKind::Select,
            Default::Text("anthropic"),
        )
        .options(PROVIDERS),
        credential_param(PROVIDERS),
        ParamSpec::new("model", "Model", ParamKind::Text, Default::Text(""))
            .hint("empty = claude-opus-5-5 for Claude"),
        ParamSpec::new("system", "Instructions", ParamKind::Text, Default::Text("")),
        ParamSpec::new(
            "prompt",
            "Prompt",
            ParamKind::Text,
            Default::Text("{{ $json.text }}"),
        ),
        ParamSpec::new("image", "Image", ParamKind::Text, Default::Text(""))
            .hint("a photo for the AI to look at, e.g. {{ $json.file.path }}"),
        ParamSpec::new(
            "json",
            "Reply as JSON",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
        ParamSpec::new(
            "timeout",
            "Timeout (seconds)",
            ParamKind::Number,
            Default::Number(120.0),
        ),
    ],
    run: run_chat,
    resume: Some(resume_chat),
    step: None,
}];
