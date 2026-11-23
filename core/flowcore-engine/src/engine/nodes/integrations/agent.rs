//! AI Agent: Claude with tools, one host round trip per turn; or Claude Code
//! running the whole task in Ubuntu. See `integrations/agent.ts`.

use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, StepResult,
};
use super::ai::{ANTHROPIC_VERSION, DEFAULT_CLAUDE_MODEL};
use super::api::{ApiCall, api_request, check_response, credential_param};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{
    Obj, Val, format_number, get_key, js_trim, obj, ordered_entries, to_num, to_template_str,
};

pub const TOOL_KINDS: &[&str] = &["http", "command", "workflow", "table", "mcp", "browser"];
const BROWSER_ACTIONS: &[&str] = &["open", "read", "click", "type", "press", "scroll", "back"];
const HTTP_METHODS: &[&str] = &["GET", "POST", "PUT", "PATCH", "DELETE"];

const PROVIDERS: &[&str] = &["anthropic", "claudeCode"];
/// What Claude Code may do without asking; each level includes the one before.
const ACCESS: &[&str] = &["readFiles", "editFiles", "runCommands"];

fn access_tools(access: &str) -> Option<&'static [&'static str]> {
    Some(match access {
        "readFiles" => &["Read", "Glob", "Grep"],
        "editFiles" => &["Read", "Glob", "Grep", "Edit", "Write"],
        "runCommands" => &["Read", "Glob", "Grep", "Edit", "Write", "Bash"],
        _ => return None,
    })
}

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
        "browser" => {
            let sites = if tool.config.is_empty() {
                String::new()
            } else {
                format!(" Only these sites: {}.", tool.config)
            };
            schema(
                obj([
                    (
                        "action",
                        Val::Obj(obj([
                            ("type", "string".into()),
                            ("enum", strs(BROWSER_ACTIONS)),
                        ])),
                    ),
                    (
                        "url",
                        prop("string", &format!("For open: the page to load.{sites}")),
                    ),
                    (
                        "target",
                        prop(
                            "string",
                            "For click and type: an element number from the last page view, like \"12\", or a CSS selector.",
                        ),
                    ),
                    (
                        "text",
                        prop(
                            "string",
                            "For type: the text to enter. For press: a key, like Enter.",
                        ),
                    ),
                ]),
                &["action"],
            )
        }
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
        "browser" => {
            "Uses a web browser on the phone, with your saved logins: open a page, then click, type and scroll. Every action returns the page as it is now, with numbered elements to use as targets."
        }
        _ => "",
    }
}

/// The node's own tools, then the MCP servers' tools, then web search.
fn api_tools(run: &NodeRun<'_>, mcp: &[Val]) -> Result<Vec<Val>> {
    let mut list: Vec<Val> = tools(run)?
        .into_iter()
        .filter(|t| t.kind != "mcp")
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
    for t in mcp {
        if let Val::Obj(t) = t {
            list.push(Val::Obj(obj([
                ("name", get_key(t, "name").clone()),
                ("description", get_key(t, "description").clone()),
                ("input_schema", get_key(t, "input_schema").clone()),
            ])));
        }
    }
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
fn ask(run: &NodeRun<'_>, index: usize, messages: &[Val], mcp: &[Val]) -> Result<Val> {
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
    let tool_list = api_tools(run, mcp)?;
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
    /// The MCP servers' tools, found before the first turn.
    mcp: Vec<Val>,
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
            ("mcp", Val::Arr(self.mcp.clone())),
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
        mcp: list("mcp"),
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
fn begin(run: &NodeRun<'_>, index: usize, outputs: Vec<Item>, mcp: Vec<Val>) -> Result<StepResult> {
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
        mcp,
        phase: String::new(),
        calls: Vec::new(),
    };
    let effect = http_effect(ask(run, index, &memo.messages, &memo.mcp)?);
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
    let effect = http_effect(ask(run, next.item_index(), &next.messages, &next.mcp)?);
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

fn provider(run: &NodeRun<'_>) -> Result<String> {
    let p = run.text("provider", 0)?;
    if !PROVIDERS.contains(&p.as_str()) {
        return fail(ErrorKind::Node, format!("unknown provider {p}"));
    }
    Ok(p)
}

/// Claude Code's MCP servers, `{name: settings}` as in its own `.mcp.json`.
fn mcp_servers(run: &NodeRun<'_>) -> Result<Obj> {
    let mut v = run.value("mcpServers", 0)?;
    if let Val::Str(s) = &v {
        v = if js_trim(s).is_empty() {
            Val::Obj(Obj::new())
        } else {
            parse_json(s, "MCP servers", ErrorKind::Input)?
        };
    }
    let Val::Obj(servers) = v else {
        return fail(
            ErrorKind::Node,
            "MCP servers must be a JSON object of name: settings",
        );
    };
    for (name, settings) in ordered_entries(&servers) {
        if !valid_name(name) {
            return fail(
                ErrorKind::Node,
                format!("MCP server name \"{name}\" must be 1–64 letters, digits, _ or -"),
            );
        }
        if !matches!(settings, Val::Obj(_)) {
            return fail(
                ErrorKind::Node,
                format!("MCP server {name} must be an object"),
            );
        }
    }
    Ok(servers)
}

/// The tools Claude Code may use without asking.
fn allowed_tools(run: &NodeRun<'_>, servers: &Obj) -> Result<Vec<Val>> {
    let access = run.text("access", 0)?;
    let Some(base) = access_tools(&access) else {
        return fail(ErrorKind::Node, format!("unknown access {access}"));
    };
    let mut list: Vec<Val> = base.iter().map(|s| Val::from(*s)).collect();
    if run.param("webSearch").is_true() {
        list.push("WebSearch".into());
        list.push("WebFetch".into());
    }
    for (name, _) in ordered_entries(servers) {
        list.push(Val::Str(format!("mcp__{name}")));
    }
    Ok(list)
}

/// One task for Claude Code; the host runs it in Ubuntu and returns the result.
fn cli_task(run: &NodeRun<'_>, index: usize, servers: &Obj, allowed: &[Val]) -> Result<Val> {
    let prompt = run.text("prompt", index)?;
    if prompt.is_empty() {
        return fail(ErrorKind::Node, "prompt is empty");
    }
    let folder = run.text("folder", index)?;
    if !folder.starts_with('/') {
        return fail(
            ErrorKind::Node,
            "folder must be a path in Ubuntu, starting with /",
        );
    }
    let timeout = to_num(&run.value("timeout", index)?);
    let steps = max_steps(run)?;
    let session = run.text("session", index)?;
    let scope = match get_key(&run.base, "$workflow") {
        Val::Obj(w) => to_template_str(get_key(w, "id")),
        _ => String::new(),
    };
    // A conversation key continues the same Claude Code session across runs of this step.
    let session = if session.is_empty() {
        String::new()
    } else {
        format!("{scope}/{}/{session}", run.node.name)
    };
    Ok(Val::Obj(obj([
        ("mode", "agent".into()),
        ("prompt", Val::Str(prompt)),
        ("system", Val::Str(run.text("system", index)?)),
        ("model", Val::Str(run.text("model", index)?)),
        ("image", "".into()),
        ("folder", Val::Str(folder)),
        ("tools", Val::Arr(allowed.to_vec())),
        ("mcpServers", Val::Obj(servers.clone())),
        ("maxTurns", Val::Num(steps)),
        ("session", Val::Str(session)),
        (
            "timeoutMs",
            Val::Num((if timeout >= 1.0 { timeout } else { 1.0 }) * 1000.0 * steps),
        ),
    ])))
}

fn start_claude_code(run: &NodeRun<'_>) -> Result<NodeResult> {
    let servers = mcp_servers(run)?;
    let allowed = allowed_tools(run, &servers)?;
    let chats = (0..run.items().len())
        .map(|i| cli_task(run, i, &servers, &allowed))
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "cliChat".into()),
        ("agent", "claudeCode".into()),
        ("chats", Val::Arr(chats)),
    ])))
}

/// Claude Code's results, one per task: `{text, model, sessionId, steps, stopReason, costUsd}` or `{error}`.
fn finish_claude_code(run: &NodeRun<'_>, result: &Obj) -> Result<StepResult> {
    if let Val::Str(error) = get_key(result, "error") {
        return fail(ErrorKind::Node, error.clone());
    }
    let Val::Arr(replies) = get_key(result, "replies") else {
        return fail(ErrorKind::Node, "Claude Code returned no result");
    };
    let mut outputs = Vec::new();
    for (i, reply) in replies.iter().enumerate() {
        let Val::Obj(reply) = reply else {
            return fail(ErrorKind::Node, "Claude Code returned no result");
        };
        if let Val::Str(failed) = get_key(reply, "error") {
            return fail(ErrorKind::Node, format!("Claude Code: {failed}"));
        }
        let text = |key: &str| match get_key(reply, key) {
            Val::Str(s) => s.clone(),
            _ => String::new(),
        };
        let model = text("model");
        let model = if model.is_empty() {
            run.text("model", i)?
        } else {
            model
        };
        outputs.push(obj([
            ("text", Val::Str(text("text"))),
            ("steps", Val::Num(to_num(get_key(reply, "steps")))),
            ("stopReason", Val::Str(text("stopReason"))),
            ("provider", "claudeCode".into()),
            ("model", Val::Str(model)),
            ("sessionId", Val::Str(text("sessionId"))),
            ("costUsd", Val::Num(to_num(get_key(reply, "costUsd")))),
        ]));
    }
    Ok(StepResult::Outputs(vec![outputs]))
}

/// Asks the host for the MCP servers' tools before the first turn.
fn discover(run: &NodeRun<'_>, servers: &[Tool]) -> Result<StepResult> {
    let timeout = to_num(&run.value("timeout", 0)?);
    let memo = Memo {
        index: 0.0,
        messages: Vec::new(),
        steps: 0.0,
        outputs: Vec::new(),
        mcp: Vec::new(),
        phase: String::new(),
        calls: Vec::new(),
    };
    let list = servers
        .iter()
        .map(|t| {
            Val::Obj(obj([
                ("name", Val::Str(t.name.clone())),
                ("config", Val::Str(t.config.clone())),
            ]))
        })
        .collect();
    Ok(StepResult::Effect(
        obj([
            ("type", "mcpList".into()),
            ("servers", Val::Arr(list)),
            (
                "timeoutMs",
                Val::Num((if timeout >= 1.0 { timeout } else { 1.0 }) * 1000.0),
            ),
        ]),
        memo.to_val(obj([("phase", "discover".into())])),
    ))
}

/// `<server>__<tool>`, as a name Claude accepts.
fn mcp_tool_name(server: &str, tool: &str) -> String {
    format!("{server}__{tool}")
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .take(64)
        .collect()
}

/// The MCP servers' tools, then the first item's first turn.
fn after_discover(run: &NodeRun<'_>, result: &Obj) -> Result<StepResult> {
    if let Val::Str(error) = get_key(result, "error") {
        return fail(ErrorKind::Node, error.clone());
    }
    let all = tools(run)?;
    let servers: Vec<&Tool> = all.iter().filter(|t| t.kind == "mcp").collect();
    let results = match get_key(result, "results") {
        Val::Arr(list) if list.len() == servers.len() => list,
        _ => {
            return fail(
                ErrorKind::Node,
                format!("expected {} MCP tool lists", servers.len()),
            );
        }
    };
    let mut used: Vec<String> = all
        .iter()
        .filter(|t| t.kind != "mcp")
        .map(|t| t.name.clone())
        .collect();
    let mut mcp = Vec::new();
    for (server, r) in servers.iter().zip(results) {
        let Val::Obj(r) = r else {
            return fail(
                ErrorKind::Node,
                format!("MCP tool {}: no tool list", server.name),
            );
        };
        if let Val::Str(failed) = get_key(r, "error") {
            return fail(
                ErrorKind::Node,
                format!("MCP tool {}: {failed}", server.name),
            );
        }
        let Val::Arr(list) = get_key(r, "tools") else {
            continue;
        };
        for t in list {
            let Val::Obj(t) = t else {
                continue;
            };
            let tool = to_template_str(get_key(t, "name"));
            if tool.is_empty() {
                continue;
            }
            let name = mcp_tool_name(&server.name, &tool);
            if used.contains(&name) {
                continue;
            }
            used.push(name.clone());
            let description = match get_key(t, "description") {
                Val::Str(d) if !d.is_empty() => d.clone(),
                _ => format!("{tool} from the {} MCP server", server.name),
            };
            let schema = match get_key(t, "inputSchema") {
                Val::Obj(o) => Val::Obj(o.clone()),
                _ => Val::Obj(obj([
                    ("type", "object".into()),
                    ("properties", Val::Obj(Obj::new())),
                ])),
            };
            mcp.push(Val::Obj(obj([
                ("name", Val::Str(name)),
                ("server", Val::Str(server.name.clone())),
                ("config", Val::Str(server.config.clone())),
                ("tool", Val::Str(tool)),
                ("description", Val::Str(description)),
                ("input_schema", schema),
            ])));
        }
    }
    begin(run, 0, Vec::new(), mcp)
}

fn start(run: &NodeRun<'_>) -> Result<NodeResult> {
    if provider(run)? == "claudeCode" {
        return start_claude_code(run);
    }
    let all = tools(run)?;
    let servers: Vec<Tool> = all.into_iter().filter(|t| t.kind == "mcp").collect();
    let first = if servers.is_empty() {
        begin(run, 0, Vec::new(), Vec::new())?
    } else {
        discover(run, &servers)?
    };
    Ok(match first {
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
fn tool_calls(run: &NodeRun<'_>, content: &[Val], mcp: &[Val]) -> Result<Vec<Val>> {
    let known: Vec<Tool> = tools(run)?
        .into_iter()
        .filter(|t| t.kind != "mcp")
        .collect();
    Ok(content
        .iter()
        .filter_map(|b| match b {
            Val::Obj(u) if get_key(u, "type").is_str("tool_use") => {
                let name = to_template_str(get_key(u, "name"));
                // Names are unique after discovery; like the reference Map, the last one wins.
                let remote = mcp.iter().rev().find_map(|t| match t {
                    Val::Obj(t) if to_template_str(get_key(t, "name")) == name => Some(t),
                    _ => None,
                });
                if let Some(remote) = remote {
                    return Some(Val::Obj(obj([
                        ("id", get_key(u, "id").clone()),
                        ("kind", "mcp".into()),
                        ("name", Val::Str(name)),
                        ("config", get_key(remote, "config").clone()),
                        ("input", get_key(u, "input").clone()),
                        ("tool", get_key(remote, "tool").clone()),
                    ])));
                }
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
    if provider(run)? == "claudeCode" {
        return finish_claude_code(run, result);
    }
    let memo = from_memo(&run.memo)?;
    if memo.phase == "discover" {
        return after_discover(run, result);
    }
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
        let calls = tool_calls(run, &content, &memo.mcp)?;
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
        return begin(run, next, outputs, memo.mcp);
    }
    Ok(StepResult::Outputs(vec![outputs]))
}

pub static AGENT_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "ai.agent",
    label: "AI Agent",
    group: NodeGroup::Ai,
    description: "Claude works on each item using the tools you give it (web APIs, commands, workflows, phone tables, web search) until it has an answer, or Claude Code does it in Ubuntu with your own Claude plan.",
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
        credential_param(&["anthropic"]),
        ParamSpec::new("model", "Model", ParamKind::Text, Default::Text(""))
            .hint("empty = claude-opus-5-5, or Claude Code's own default"),
        ParamSpec::new("system", "Instructions", ParamKind::Text, Default::Text("")),
        ParamSpec::new(
            "prompt",
            "Task",
            ParamKind::Text,
            Default::Text("{{ $json.text }}"),
        ),
        ParamSpec::new("tools", "Tools", ParamKind::Tools, Default::EmptyList).hint(
            "an mcp tool takes a saved MCP server’s name, a URL or a command, and brings all its tools; a browser tool takes the sites it may visit",
        ),
        ParamSpec::new(
            "access",
            "Claude Code may",
            ParamKind::Select,
            Default::Text("readFiles"),
        )
        .options(ACCESS),
        ParamSpec::new("folder", "Folder", ParamKind::Text, Default::Text("/root/files"))
            .hint("where Claude Code works, in Ubuntu"),
        ParamSpec::new("mcpServers", "MCP servers", ParamKind::Json, Default::Text("{}")).hint(
            "Claude Code’s .mcp.json servers, e.g. {\"docs\": {\"type\": \"http\", \"url\": \"https://…/mcp\"}}",
        ),
        ParamSpec::new("session", "Conversation key", ParamKind::Text, Default::Text("")).hint(
            "same key = Claude Code continues that conversation, e.g. {{ $json.chatId }}",
        ),
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
