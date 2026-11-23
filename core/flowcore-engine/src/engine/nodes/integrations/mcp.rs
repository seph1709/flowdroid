//! MCP Client: calls a Model Context Protocol server's tools, resources and
//! prompts; the host speaks the protocol. See `integrations/mcp.ts`.

use super::super::http::AUTH_CREDENTIALS;
use super::super::spec::{Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec};
use super::api::credential_param;
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{Obj, Val, get_key, js_trim, obj, to_num};

pub const MCP_TRANSPORTS: &[&str] = &["http", "stdio", "saved"];
const OPERATION_NAMES: &[&str] = &[
    "callTool",
    "listTools",
    "readResource",
    "listResources",
    "getPrompt",
    "listPrompts",
];

/// The JSON-RPC method for an operation.
fn method_of(op: &str) -> Option<&'static str> {
    Some(match op {
        "callTool" => "tools/call",
        "listTools" => "tools/list",
        "readResource" => "resources/read",
        "listResources" => "resources/list",
        "getPrompt" => "prompts/get",
        "listPrompts" => "prompts/list",
        _ => return None,
    })
}

fn operation(run: &NodeRun<'_>) -> Result<String> {
    let op = run.text("operation", 0)?;
    if method_of(&op).is_none() {
        return fail(ErrorKind::Node, format!("unknown operation {op}"));
    }
    Ok(op)
}

/// Where the server is; the same for every item.
fn server(run: &NodeRun<'_>) -> Result<Obj> {
    let transport = run.text("transport", 0)?;
    match transport.as_str() {
        "http" => {
            let url = run.text("url", 0)?;
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return fail(
                    ErrorKind::Node,
                    "the server URL must start with http:// or https://",
                );
            }
            let mut out = obj([("transport", Val::Str(transport)), ("url", Val::Str(url))]);
            let credential = run.text("credential", 0)?;
            if !credential.is_empty() {
                out.insert("credential".into(), Val::Str(credential));
            }
            Ok(out)
        }
        "stdio" => {
            let command = run.text("command", 0)?;
            if command.is_empty() {
                return fail(ErrorKind::Node, "command is empty");
            }
            Ok(obj([
                ("transport", Val::Str(transport)),
                ("command", Val::Str(command)),
            ]))
        }
        "saved" => {
            // An "MCP server" credential: its URL or command, and the key it signs in with.
            let credential = run.text("server", 0)?;
            if credential.is_empty() {
                return fail(ErrorKind::Node, "choose a saved MCP server");
            }
            Ok(obj([
                ("transport", Val::Str(transport)),
                ("credential", Val::Str(credential)),
            ]))
        }
        _ => fail(ErrorKind::Node, format!("unknown transport {transport}")),
    }
}

/// The arguments object; text is parsed as JSON.
fn args(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let mut v = run.value("arguments", index)?;
    if let Val::Str(s) = &v {
        if js_trim(s).is_empty() {
            return Ok(Val::Obj(Obj::new()));
        }
        v = parse_json(s, "arguments", ErrorKind::Input)?;
    }
    if !matches!(v, Val::Obj(_)) {
        return fail(ErrorKind::Node, "arguments must be a JSON object");
    }
    Ok(v)
}

fn required(run: &NodeRun<'_>, key: &str, index: usize, what: &str) -> Result<String> {
    let v = run.text(key, index)?;
    if v.is_empty() {
        return fail(ErrorKind::Node, format!("{what} is empty"));
    }
    Ok(v)
}

/// The JSON-RPC request for item [index].
fn call(run: &NodeRun<'_>, op: &str, index: usize) -> Result<Val> {
    let method = method_of(op).unwrap_or_default();
    let params = match op {
        "callTool" | "getPrompt" => {
            let what = if op == "callTool" {
                "tool name"
            } else {
                "prompt name"
            };
            let name = required(run, "name", index, what)?;
            obj([("name", Val::Str(name)), ("arguments", args(run, index)?)])
        }
        "readResource" => obj([(
            "uri",
            Val::Str(required(run, "uri", index, "resource URI")?),
        )]),
        _ => Obj::new(),
    };
    Ok(Val::Obj(obj([
        ("method", method.into()),
        ("params", Val::Obj(params)),
    ])))
}

fn run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let op = operation(run)?;
    let srv = server(run)?;
    let calls = (0..run.items().len())
        .map(|i| call(run, &op, i))
        .collect::<Result<Vec<_>>>()?;
    let timeout = to_num(&run.value("timeout", 0)?);
    Ok(NodeResult::Effect(obj([
        ("type", "mcp".into()),
        ("server", Val::Obj(srv)),
        ("calls", Val::Arr(calls)),
        (
            "timeoutMs",
            Val::Num((if timeout >= 1.0 { timeout } else { 1.0 }) * 1000.0),
        ),
    ])))
}

/// The text blocks of an MCP content list, joined.
fn text_of(list: &Val) -> String {
    let Val::Arr(list) = list else {
        return String::new();
    };
    list.iter()
        .filter_map(|b| match b {
            Val::Obj(o) => match get_key(o, "text") {
                Val::Str(s) => Some(s.clone()),
                _ => None,
            },
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn to_item(op: &str, result: &Obj) -> Result<Item> {
    match op {
        "callTool" => {
            let text = text_of(get_key(result, "content"));
            if get_key(result, "isError").is_true() {
                let details = if text.is_empty() {
                    "no details".to_owned()
                } else {
                    text
                };
                return fail(ErrorKind::Node, format!("the tool failed: {details}"));
            }
            let mut item = obj([
                ("text", Val::Str(text)),
                ("content", get_key(result, "content").clone()),
            ]);
            let structured = get_key(result, "structuredContent");
            if !structured.is_null() {
                item.insert("json".into(), structured.clone());
            }
            Ok(item)
        }
        "readResource" => Ok(obj([
            ("text", Val::Str(text_of(get_key(result, "contents")))),
            ("contents", get_key(result, "contents").clone()),
        ])),
        _ => Ok(result.clone()),
    }
}

fn resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    if let Val::Str(error) = get_key(result, "error") {
        return fail(ErrorKind::Node, error.clone());
    }
    let Val::Arr(results) = get_key(result, "results") else {
        return fail(ErrorKind::Node, "the MCP server returned no result");
    };
    let op = operation(run)?;
    let mut out = Vec::new();
    for r in results {
        let Val::Obj(r) = r else {
            return fail(ErrorKind::Node, "the MCP server returned no result");
        };
        if let Val::Str(failed) = get_key(r, "error") {
            return fail(ErrorKind::Node, format!("MCP: {failed}"));
        }
        let Val::Obj(body) = get_key(r, "result") else {
            return fail(ErrorKind::Node, "the MCP server returned no result");
        };
        out.push(to_item(&op, body)?);
    }
    Ok(vec![out])
}

pub static MCP_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "mcp.client",
    label: "MCP Client",
    group: NodeGroup::Ai,
    description: "Calls a tool, reads a resource or gets a prompt from an MCP server, on the web or run in Ubuntu.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        ParamSpec::new(
            "transport",
            "Server type",
            ParamKind::Select,
            Default::Text("http"),
        )
        .options(MCP_TRANSPORTS),
        ParamSpec::new(
            "server",
            "Saved server",
            ParamKind::Credential,
            Default::Text(""),
        )
        .options(&["mcpServer"])
        .hint("add one in Settings → Credentials → MCP server"),
        ParamSpec::new("url", "Server URL", ParamKind::Text, Default::Text(""))
            .hint("e.g. https://example.com/mcp"),
        ParamSpec {
            label: "Authentication",
            hint: Some("empty = none"),
            ..credential_param(AUTH_CREDENTIALS)
        },
        ParamSpec::new("command", "Command", ParamKind::Text, Default::Text(""))
            .hint("runs in Ubuntu, e.g. npx -y @modelcontextprotocol/server-everything"),
        ParamSpec::new(
            "operation",
            "Operation",
            ParamKind::Select,
            Default::Text("callTool"),
        )
        .options(OPERATION_NAMES),
        ParamSpec::new("name", "Tool or prompt", ParamKind::Text, Default::Text("")),
        ParamSpec::new("uri", "Resource URI", ParamKind::Text, Default::Text("")),
        ParamSpec::new(
            "arguments",
            "Arguments",
            ParamKind::Json,
            Default::Text("{}"),
        ),
        ParamSpec::new(
            "timeout",
            "Timeout (seconds)",
            ParamKind::Number,
            Default::Number(60.0),
        ),
    ],
    run,
    resume: Some(resume),
    step: None,
}];
