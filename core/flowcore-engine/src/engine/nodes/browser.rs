//! Browser: drives the phone's in-app browser through a short script per item;
//! the host parses and runs it. See `nodes/browser.ts`.

use super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj, to_num};

fn run(run: &NodeRun<'_>) -> Result<NodeResult> {
    let runs = (0..run.items().len())
        .map(|i| {
            let url = run.text("url", i)?;
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return fail(
                    ErrorKind::Node,
                    "the URL must start with http:// or https://",
                );
            }
            Ok(Val::Obj(obj([
                ("url", Val::Str(url)),
                ("steps", Val::Str(run.text("steps", i)?)),
            ])))
        })
        .collect::<Result<Vec<_>>>()?;
    let timeout = to_num(&run.value("timeout", 0)?);
    Ok(NodeResult::Effect(obj([
        ("type", "browser".into()),
        ("runs", Val::Arr(runs)),
        ("visible", Val::Bool(run.param("visible").is_true())),
        ("fast", Val::Bool(run.param("fast").is_true())),
        (
            "timeoutMs",
            Val::Num((if timeout >= 1.0 { timeout } else { 1.0 }) * 1000.0),
        ),
    ])))
}

fn resume(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let Val::Arr(results) = get_key(result, "results") else {
        return fail(ErrorKind::Node, "the browser returned no result");
    };
    let field = run.text("field", 0)?;
    let mut out = Vec::new();
    for (i, item) in run.items().iter().enumerate() {
        let Some(Val::Obj(r)) = results.get(i) else {
            return fail(ErrorKind::Node, "the browser returned no result");
        };
        if let Val::Str(failed) = get_key(r, "error") {
            return fail(ErrorKind::Node, format!("Browser: {failed}"));
        }
        let mut copy = item.clone();
        copy.insert(field.clone(), Val::Obj(r.clone()));
        out.push(copy);
    }
    Ok(vec![out])
}

pub static BROWSER_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "browser.run",
    label: "Browser",
    group: NodeGroup::Network,
    description: "Opens a page in the phone\u{2019}s browser (with your saved logins) and clicks, types and reads it, step by step.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        ParamSpec::new(
            "url",
            "Start at",
            ParamKind::Text,
            Default::Text("https://"),
        )
        .hint("the page to open first"),
        ParamSpec::new(
            "steps",
            "Steps",
            ParamKind::Code,
            Default::Text("extract heading h1"),
        )
        .hint("one per line: click, type, press, wait, extract, scroll, back, screenshot, js"),
        ParamSpec::new(
            "visible",
            "Show the browser while it runs",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
        ParamSpec::new(
            "fast",
            "Fast mode (skip images, fonts and video)",
            ParamKind::Boolean,
            Default::Bool(true),
        ),
        ParamSpec::new(
            "timeout",
            "Timeout (seconds)",
            ParamKind::Number,
            Default::Number(60.0),
        ),
        ParamSpec::new(
            "field",
            "Output field",
            ParamKind::Text,
            Default::Text("browser"),
        ),
    ],
    run,
    resume: Some(resume),
    step: None,
}];
