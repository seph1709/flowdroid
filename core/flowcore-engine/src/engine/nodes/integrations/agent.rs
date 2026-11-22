//! AI Agent: Claude with tools, one host round trip per turn; see `integrations/agent.ts`.

use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, StepResult,
};
use super::ai::{ANTHROPIC_VERSION, DEFAULT_CLAUDE_MODEL};
use super::api::{ApiCall, api_request, check_response, credential_param};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, format_number, get_key, obj, to_num, to_template_str};

pub const TOOL_KINDS: &[&str] = &["http", "command", "workflow", "table"];
const HTTP_METHODS: &[&str] = &["GET", "POST", "PUT", "PATCH", "DELETE"];

struct Tool {
    kind: String,
    name: String,
    description: String,
    config: String,
}

fn valid_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The tools the node is set up with, checked.
fn tools(run: &NodeRun<'_>) -> Result<Vec<Tool>> {
    let mut out: Vec<Tool> = Vec::new();
    for (i, row) in run.rows("tools")?.into_iter().enumerate() {
        let kind = to_template_str(get_key(row, "kind"));
        if !TOOL_KINDS.contains(&kind.as_str()) {
            return fail(
                ErrorKind::Node,
                format!("tool {}: unknown kind {kind}", i + 1),
            );
        }
        let name = to_template_str(get_key(row, "name"));
        if !valid_name(&name) {
            return fail(
                ErrorKind::Node,
                format!("tool name \"{name}\" must be 1–64 letters, digits, _ or -"),
            );
        }
        if out.iter().any(|t| t.name == name) {
            return fail(ErrorKind::Node, format!("two tools are named {name}"));
        }
        out.push(Tool {
            kind,
            name,
            description: to_template_str(get_key(row, "description")),
            config: to_template_str(get_key(row, "config")),
        });
    }
    Ok(out)
}

fn strs(list: &[&str]) -> Val {
    Val::Arr(list.iter().map(|s| Val::from(*s)).collect())
}

fn schema(properties: Obj, required: &[&str]) -> Val {
    Val::Obj(obj([
        ("type", "object".into()),
        ("properties", Val::Obj(properties)),
        ("required", strs(required)),
    ]))
}

fn prop(kind: &str, description: &str) -> Val {
    Val::Obj(obj([
        ("type", kind.into()),
        ("description", description.into()),
    ]))
}

fn tool_schema(tool: &Tool) -> Val {
    match tool.kind.as_str() {
        "http" => {
            let url = if tool.config.is_empty() {
                "The full URL.".to_owned()
            } else {
                format!("The full URL; it must start with {}", tool.config)
            };
            schema(
                obj([
                    (
                        "method",
                        Val::Obj(obj([
                            ("type", "string".into()),
                            ("enum", strs(HTTP_METHODS)),
                        ])),
                    ),
                    ("url", prop("string", &url)),
                    ("body", prop("string", "Request body, usually JSON.")),
                ]),
                &["url"],
            )
        }
        "command" => schema(
            obj([(
                "command",
                prop("string", "A shell command; its output is returned."),
            )]),
            &["command"],
        ),
        "workflow" => schema(
            obj([(
                "input",
                prop("object", "Data the workflow receives as its item."),
            )]),
            &[],
        ),
        _ => schema(
            obj([
                (
                    "operation",
                    Val::Obj(obj([
                        ("type", "string".into()),
                        ("enum", strs(&["find", "insert", "update", "delete"])),
                    ])),
                ),
                (
                    "where",
                    prop("object", "Column: value pairs a row must match."),
                ),
                (
                    "row",
                    prop("object", "Values to insert, or to set on matching rows."),
                ),
            ]),
            &["operation"],
        ),
    }
}

fn default_description(kind: &str) -> &'static str {
    match kind {
        "http" => "Calls a web API and returns the response.",
        "command" => "Runs a shell command and returns what it printed.",
        "workflow" => "Runs a FlowDroid workflow and returns its output.",
        "table" => "Reads or changes rows in a table stored on the phone.",
        _ => "",
    }
}

fn api_tools(run: &NodeRun<'_>) -> Result<Vec<Val>> {
    let mut list: Vec<Val> = tools(run)?
        .into_iter()
        .map(|t| {
            let description = if t.description.is_empty() {
                default_description(&t.kind).to_owned()
            } else {
                t.description.clone()
            };
            Val::Obj(obj([
                ("name", Val::Str(t.name.clone())),
                ("description", Val::Str(description)),
                ("input_schema", tool_schema(&t)),
            ]))
        })
        .collect();
    if run.param("webSearch").is_true() {
        list.push(Val::Obj(obj([
            ("type", "web_search_20260209".into()),
            ("name", "web_search".into()),
        ])));
    }
    Ok(list)
}

fn max_steps(run: &NodeRun<'_>) -> Result<f64> {
    let n = to_num(&run.value("maxSteps", 0)?).trunc();
    Ok(if n >= 1.0 { n } else { 1.0 })
}

/// One call to Claude with the conversation so far.
fn ask(run: &NodeRun<'_>, index: usize, messages: &[Val]) -> Result<Val> {
    let model = run.text("model", index)?;
    let system = run.text("system", index)?;
    let timeout = to_num(&run.value("timeout", index)?);
    let mut body = obj([
        (
            "model",
            Val::Str(if model.is_empty() {
                DEFAULT_CLAUDE_MODEL.to_owned()
            } else {
                model
            }),
        ),
        ("max_tokens", Val::Num(16000.0)),
    ]);
    if !system.is_empty() {
        body.insert("system".into(), Val::Str(system));
    }
    body.insert("messages".into(), Val::Arr(messages.to_vec()));
    let tool_list = api_tools(run)?;
    if !tool_list.is_empty() {
        body.insert("tools".into(), Val::Arr(tool_list));
    }
    body.insert(
        "thinking".into(),
        Val::Obj(obj([("type", "adaptive".into())])),
    );
    body.insert("fallbacks".into(), "default".into());
    let call = ApiCall::new("POST", "https://api.anthropic.com/v1/messages")
        .header("x-api-key", "{cred:apiKey}")
        .header("anthropic-version", ANTHROPIC_VERSION)
        .header("anthropic-beta", "server-side-fallback-2026-07-01")
        .body(Val::Obj(body))
        .timeout((if timeout >= 1.0 { timeout } else { 1.0 }) * 1000.0);
    api_request(run, call)
}

struct Memo {
    index: f64,
    messages: Vec<Val>,
    steps: f64,
    outputs: Vec<Item>,
    phase: String,
    calls: Vec<Val>,
}

impl Memo {
    fn to_val(&self, extra: Obj) -> Val {
        let mut o = obj([
            ("index", Val::Num(self.index)),
            ("messages", Val::Arr(self.messages.clone())),
            ("steps", Val::Num(self.steps)),
            (
                "outputs",
                Val::Arr(self.outputs.iter().cloned().map(Val::Obj).collect()),
            ),
        ]);
        o.extend(extra);
        Val::Obj(o)
    }

    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    fn item_index(&self) -> usize {
        self.index as usize
    }
}

fn from_memo(v: &Val) -> Result<Memo> {
    let Val::Obj(o) = v else {
        return fail(ErrorKind::Node, "the agent lost its place");
    };
    let list = |key: &str| match get_key(o, key) {
        Val::Arr(list) => list.clone(),
        _ => Vec::new(),
    };
    Ok(Memo {
        index: to_num(get_key(o, "index")),
        messages: list("messages"),
        steps: to_num(get_key(o, "steps")),
        outputs: list("outputs")
            .into_iter()
            .filter_map(|x| x.as_obj().cloned())
            .collect(),
        phase: to_template_str(get_key(o, "phase")),
        calls: list("calls"),
    })
}

fn http_effect(request: Val) -> Obj {
    obj([
        ("type", "http".into()),
        ("requests", Val::Arr(vec![request])),
    ])
}

/// Starts the conversation for item [index].
fn begin(run: &NodeRun<'_>, index: usize, outputs: Vec<Item>) -> Result<StepResult> {
    let prompt = run.text("prompt", index)?;
    if prompt.is_empty() {
        return fail(ErrorKind::Node, "prompt is empty");
    }
    let messages = vec![Val::Obj(obj([
        ("role", "user".into()),
        ("content", Val::Str(prompt)),
    ]))];
    #[allow(clippy::cast_precision_loss)]
    let memo = Memo {
        index: index as f64,
        messages,
        steps: 1.0,
        outputs,
        phase: String::new(),
        calls: Vec::new(),
    };
    let effect = http_effect(ask(run, index, &memo.messages)?);
    Ok(StepResult::Effect(
        effect,
        memo.to_val(obj([("phase", "model".into())])),
    ))
}

/// Asks Claude again, unless the step budget is spent.
fn ask_again(run: &NodeRun<'_>, memo: Memo) -> Result<StepResult> {
    let limit = max_steps(run)?;
    if memo.steps >= limit {
        return fail(
            ErrorKind::Node,
            format!(
                "stopped after {} steps without a final answer",
                format_number(limit)
            ),
        );
    }
    let next = Memo {
        steps: memo.steps + 1.0,
        ..memo
    };
    let effect = http_effect(ask(run, next.item_index(), &next.messages)?);
    Ok(StepResult::Effect(
        effect,
        next.to_val(obj([("phase", "model".into())])),
    ))
}

fn text_of(content: &[Val]) -> String {
    content
        .iter()
        .filter_map(|b| match b {
            Val::Obj(o) if get_key(o, "type").is_str("text") => {
                Some(to_template_str(get_key(o, "text")))
            }
            _ => None,
        })
        .collect()
}

fn start(run: &NodeRun<'_>) -> Result<NodeResult> {
    tools(run)?;
    Ok(match begin(run, 0, Vec::new())? {
        StepResult::Outputs(outputs) => NodeResult::Outputs(outputs),
        StepResult::Effect(effect, memo) => NodeResult::EffectWithMemo(effect, memo),
    })
}

/// Sends the tools' results back to Claude.
fn after_tools(run: &NodeRun<'_>, memo: Memo, result: &Obj) -> Result<StepResult> {
    let results = get_key(result, "results");
    if let Val::Str(error) = get_key(result, "error") {
        return fail(ErrorKind::Node, error.clone());
    }
    let results = match results {
        Val::Arr(list) if list.len() == memo.calls.len() => list,
        _ => {
            return fail(
                ErrorKind::Node,
                format!("expected {} tool results", memo.calls.len()),
            );
        }
    };
    let content = memo
        .calls
        .iter()
        .zip(results)
        .map(|(id, r)| {
            let text = match r {
                Val::Obj(o) => to_template_str(get_key(o, "content")),
                other => to_template_str(other),
            };
            let mut block = obj([
                ("type", "tool_result".into()),
                ("tool_use_id", id.clone()),
                ("content", Val::Str(text)),
            ]);
            if matches!(r, Val::Obj(o) if get_key(o, "isError").is_true()) {
                block.insert("is_error".into(), Val::Bool(true));
            }
            Val::Obj(block)
        })
        .collect();
    let mut messages = memo.messages.clone();
    messages.push(Val::Obj(obj([
        ("role", "user".into()),
        ("content", Val::Arr(content)),
    ])));
    ask_again(run, Memo { messages, ..memo })
}

/// The tool calls in Claude's reply, each with the tool's kind and settings.
fn tool_calls(run: &NodeRun<'_>, content: &[Val]) -> Result<Vec<Val>> {
    let known = tools(run)?;
    Ok(content
        .iter()
        .filter_map(|b| match b {
            Val::Obj(u) if get_key(u, "type").is_str("tool_use") => {
                let name = to_template_str(get_key(u, "name"));
                let tool = known.iter().find(|t| t.name == name);
                Some(Val::Obj(obj([
                    ("id", get_key(u, "id").clone()),
                    (
                        "kind",
                        Val::Str(tool.map(|t| t.kind.clone()).unwrap_or_default()),
                    ),
                    ("name", Val::Str(name)),
                    (
                        "config",
                        Val::Str(tool.map(|t| t.config.clone()).unwrap_or_default()),
                    ),
                    ("input", get_key(u, "input").clone()),
                ])))
            }
            _ => None,
        })
        .collect())
}

fn step(run: &NodeRun<'_>, result: &Obj) -> Result<StepResult> {
    let memo = from_memo(&run.memo)?;
    if memo.phase == "tools" {
        return after_tools(run, memo, result);
    }

    let response = match get_key(result, "responses") {
        Val::Arr(list) if !list.is_empty() => list[0].clone(),
        _ => return fail(ErrorKind::Node, "Claude returned no response"),
    };
    let Val::Obj(body) = check_response("Claude", &response)? else {
        return fail(ErrorKind::Node, "Claude returned no message");
    };
    let stop = get_key(&body, "stop_reason").clone();
    if stop.is_str("refusal") {
        return fail(ErrorKind::Node, "Claude declined this request");
    }
    let content = match get_key(&body, "content") {
        Val::Arr(list) => list.clone(),
        _ => Vec::new(),
    };
    let mut messages = memo.messages.clone();
    messages.push(Val::Obj(obj([
        ("role", "assistant".into()),
        ("content", Val::Arr(content.clone())),
    ])));

    if stop.is_str("tool_use") {
        let calls = tool_calls(run, &content)?;
        let ids: Vec<Val> = calls
            .iter()
            .map(|c| c.as_obj().map_or(Val::Null, |c| get_key(c, "id").clone()))
            .collect();
        let next = Memo { messages, ..memo };
        let memo_val = next.to_val(obj([("phase", "tools".into()), ("calls", Val::Arr(ids))]));
        return Ok(StepResult::Effect(
            obj([("type", "tools".into()), ("calls", Val::Arr(calls))]),
            memo_val,
        ));
    }
    if stop.is_str("pause_turn") {
        return ask_again(run, Memo { messages, ..memo });
    }

    let mut outputs = memo.outputs.clone();
    outputs.push(obj([
        ("text", Val::Str(text_of(&content))),
        ("steps", Val::Num(memo.steps)),
        ("stopReason", stop),
    ]));
    let next = memo.item_index() + 1;
    if next < run.items().len() {
        return begin(run, next, outputs);
    }
    Ok(StepResult::Outputs(vec![outputs]))
}

pub static AGENT_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "ai.agent",
    label: "AI Agent",
    group: NodeGroup::Ai,
    description: "Claude works on each item using the tools you give it (web APIs, commands, workflows, phone tables, web search) until it has an answer.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        credential_param(&["anthropic"]),
        ParamSpec::new("model", "Model", ParamKind::Text, Default::Text(""))
            .hint("empty = claude-opus-5-5"),
        ParamSpec::new("system", "Instructions", ParamKind::Text, Default::Text("")),
        ParamSpec::new(
            "prompt",
            "Task",
            ParamKind::Text,
            Default::Text("{{ $json.text }}"),
        ),
        ParamSpec::new("tools", "Tools", ParamKind::Tools, Default::EmptyList),
        ParamSpec::new(
            "webSearch",
            "Let it search the web",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
        ParamSpec::new(
            "maxSteps",
            "Most steps",
            ParamKind::Number,
            Default::Number(10.0),
        ),
        ParamSpec::new(
            "timeout",
            "Timeout per step (seconds)",
            ParamKind::Number,
            Default::Number(120.0),
        ),
    ],
    run: start,
    resume: None,
    step: Some(step),
}];
