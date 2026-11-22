//! Code: JavaScript or Python the host runs in FlowDroid's Ubuntu; see `nodes/code.ts`.

use super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, js_trim, obj};

const LANGUAGES: &[&str] = &["javascript", "python"];
const MODES: &[&str] = &["allItems", "eachItem"];

const DEFAULT_CODE: &str = "// items: the input items. Return the items to output.\n\
// In Python: same names, e.g. return [{**item, \"checked\": True} for item in items]\n\
return items.map((item) => ({ ...item, checked: true }));";

/// What the code returned, as items: objects as they are, other values as `{ value }`, null as nothing.
fn to_items(v: &Val) -> Vec<Item> {
    let one = |x: &Val| match x {
        Val::Obj(o) => o.clone(),
        other => obj([("value", other.clone())]),
    };
    match v {
        Val::Null => Vec::new(),
        Val::Arr(list) => list.iter().map(one).collect(),
        other => vec![one(other)],
    }
}

fn run_code(run: &NodeRun<'_>) -> Result<NodeResult> {
    let language = run.text("language", 0)?;
    if !LANGUAGES.contains(&language.as_str()) {
        return fail(ErrorKind::Node, format!("unknown language {language}"));
    }
    let mode = run.text("mode", 0)?;
    if !MODES.contains(&mode.as_str()) {
        return fail(ErrorKind::Node, format!("unknown mode {mode}"));
    }
    // The code is not a template: `{{ }}` inside it is the language's own syntax.
    let code = match run.param("code") {
        Val::Str(code) if !js_trim(code).is_empty() => code.clone(),
        _ => return fail(ErrorKind::Node, "code is empty"),
    };
    let timeout = run.number("timeout", 0)?;
    Ok(NodeResult::Effect(obj([
        ("type", "code".into()),
        ("language", Val::Str(language)),
        ("mode", Val::Str(mode)),
        ("code", Val::Str(code)),
        (
            "items",
            Val::Arr(run.items().iter().cloned().map(Val::Obj).collect()),
        ),
        (
            "timeoutMs",
            Val::Num((if timeout > 0.0 { timeout } else { 60.0 }) * 1000.0),
        ),
    ])))
}

fn code_results(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let results = get_key(result, "results");
    if run.text("mode", 0)? == "allItems" {
        return Ok(vec![to_items(results)]);
    }
    let expected = run.items().len();
    match results {
        Val::Arr(list) if list.len() == expected => {
            Ok(vec![list.iter().flat_map(to_items).collect()])
        }
        _ => fail(ErrorKind::Node, format!("expected {expected} code results")),
    }
}

pub static CODE_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "core.code",
    label: "Code",
    group: NodeGroup::Data,
    description: "Runs your JavaScript or Python on the items (in FlowDroid’s Ubuntu) and outputs what it returns.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        ParamSpec::new(
            "language",
            "Language",
            ParamKind::Select,
            Default::Text("javascript"),
        )
        .options(LANGUAGES),
        ParamSpec::new("mode", "Run", ParamKind::Select, Default::Text("allItems"))
            .options(MODES)
            .hint("all items once, or once per item (as `item`)"),
        ParamSpec::new("code", "Code", ParamKind::Code, Default::Text(DEFAULT_CODE)),
        ParamSpec::new(
            "timeout",
            "Timeout (seconds)",
            ParamKind::Number,
            Default::Number(60.0),
        ),
    ],
    run: run_code,
    resume: Some(code_results),
    step: None,
}];
