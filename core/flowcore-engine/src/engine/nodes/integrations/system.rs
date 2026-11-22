//! Execute Command; see `integrations/system.ts`.

use super::super::spec::{Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, format_number, get_key, js_trim, obj, to_num, to_template_str};

fn command_effect(run: &NodeRun<'_>) -> Result<NodeResult> {
    let target = run.text("target", 0)?;
    if target != "phone" && target != "ubuntu" {
        return fail(ErrorKind::Node, format!("unknown target {target}"));
    }
    let mut commands = Vec::new();
    for i in 0..run.items().len() {
        let command = run.text("command", i)?;
        if command.is_empty() {
            return fail(ErrorKind::Node, "command is empty");
        }
        let timeout = to_num(&run.value("timeout", i)?);
        commands.push(Val::Obj(obj([
            ("target", Val::Str(target.clone())),
            ("command", Val::Str(command)),
            ("workdir", Val::Str(run.text("workdir", i)?)),
            (
                "timeoutMs",
                Val::Num((if timeout > 0.0 { timeout } else { 60.0 }) * 1000.0),
            ),
        ])));
    }
    Ok(NodeResult::Effect(obj([
        ("type", "command".into()),
        ("commands", Val::Arr(commands)),
    ])))
}

fn command_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    if let Val::Str(error) = get_key(result, "error") {
        return fail(ErrorKind::Node, error.clone());
    }
    let expected = run.items().len();
    let results = match get_key(result, "results") {
        Val::Arr(list) if list.len() == expected => list,
        _ => {
            return fail(
                ErrorKind::Node,
                format!("expected {expected} command results"),
            );
        }
    };
    let ignore_exit = run.param("ignoreExitCode").is_true();
    let mut out = Vec::new();
    for r in results {
        let empty = Obj::new();
        let res = r.as_obj().unwrap_or(&empty);
        if let Val::Str(failed) = get_key(res, "error") {
            return fail(ErrorKind::Node, failed.clone());
        }
        let exit_code = to_num(get_key(res, "exitCode"));
        let stdout = to_template_str(get_key(res, "stdout"));
        let stderr = to_template_str(get_key(res, "stderr"));
        if exit_code != 0.0 && !ignore_exit {
            let detail = if stderr.is_empty() {
                String::new()
            } else {
                format!(": {}", js_trim(&stderr))
            };
            return fail(
                ErrorKind::Node,
                format!(
                    "command exited with code {}{detail}",
                    format_number(exit_code)
                ),
            );
        }
        out.push(obj([
            ("exitCode", Val::Num(exit_code)),
            ("stdout", Val::Str(stdout)),
            ("stderr", Val::Str(stderr)),
        ]));
    }
    Ok(vec![out])
}

pub static SYSTEM_NODES: &[NodeSpec] = &[NodeSpec {
    type_name: "system.command",
    label: "Execute Command",
    group: NodeGroup::System,
    description: "Runs a shell command on the phone or in FlowDroid’s built-in Ubuntu and outputs what it printed.",
    inputs: 1,
    outputs: Some(&["main"]),
    params: &[
        ParamSpec::new(
            "target",
            "Run in",
            ParamKind::Select,
            Default::Text("phone"),
        )
        .options(&["phone", "ubuntu"]),
        ParamSpec::new(
            "command",
            "Command",
            ParamKind::Text,
            Default::Text("echo hello"),
        ),
        ParamSpec::new(
            "workdir",
            "Working directory",
            ParamKind::Text,
            Default::Text(""),
        )
        .hint("empty = home"),
        ParamSpec::new(
            "timeout",
            "Timeout (seconds)",
            ParamKind::Number,
            Default::Number(60.0),
        ),
        ParamSpec::new(
            "ignoreExitCode",
            "Continue on non-zero exit",
            ParamKind::Boolean,
            Default::Bool(false),
        ),
    ],
    run: command_effect,
    resume: Some(command_items),
    step: None,
}];
