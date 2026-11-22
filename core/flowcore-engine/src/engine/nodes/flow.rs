//! Nodes that route items: branching, filtering, merging and pausing.

use super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, pass_through,
    resume_pass_through,
};
use crate::engine::conditions::{as_conditions, matches, matches_all};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, items_val, obj, to_str};

const CONDITION_PARAMS: &[ParamSpec] = &[
    ParamSpec::new(
        "conditions",
        "Conditions",
        ParamKind::Conditions,
        Default::EmptyList,
    ),
    ParamSpec::new(
        "combine",
        "Combine",
        ParamKind::Select,
        Default::Text("and"),
    )
    .options(&["and", "or"]),
];

fn partition(run: &NodeRun<'_>) -> Result<[Vec<Item>; 2]> {
    let (conditions, combine) = as_conditions(&run.params);
    let mut kept = Vec::new();
    let mut rejected = Vec::new();
    for (i, item) in run.items().iter().enumerate() {
        let target = if matches_all(conditions, combine, &run.scope(i))? {
            &mut kept
        } else {
            &mut rejected
        };
        target.push(item.clone());
    }
    Ok([kept, rejected])
}

fn if_node(run: &NodeRun<'_>) -> Result<NodeResult> {
    Ok(NodeResult::Outputs(partition(run)?.into()))
}

fn filter(run: &NodeRun<'_>) -> Result<NodeResult> {
    let [kept, _] = partition(run)?;
    Ok(NodeResult::Outputs(vec![kept]))
}

fn switch(run: &NodeRun<'_>) -> Result<NodeResult> {
    let rules = run.rows("rules")?;
    let fallback = run.param("fallback").is_true();
    let mut outputs = vec![Vec::new(); rules.len() + usize::from(fallback)];
    for (i, item) in run.items().iter().enumerate() {
        let scope = run.scope(i);
        let mut hit = None;
        for (r, rule) in rules.iter().enumerate() {
            if matches(&Val::Obj((*rule).clone()), &scope, r)? {
                hit = Some(r);
                break;
            }
        }
        let target = hit.or(if fallback { Some(rules.len()) } else { None });
        if let Some(output) = target.and_then(|t| outputs.get_mut(t)) {
            output.push(item.clone());
        }
    }
    Ok(NodeResult::Outputs(outputs))
}

/// Merge waits for every connected input; the executor hands it all of them at once.
fn merge(run: &NodeRun<'_>) -> Result<NodeResult> {
    let empty = Vec::new();
    let first = run.inputs.first().unwrap_or(&empty);
    let second = run.inputs.get(1).unwrap_or(&empty);
    let mode = to_str(run.param("mode"));
    let merged = match mode.as_str() {
        "append" => first.iter().chain(second).cloned().collect(),
        "combineByIndex" => first
            .iter()
            .zip(second)
            .map(|(a, b)| {
                let mut out = a.clone();
                out.extend(b.iter().map(|(k, v)| (k.clone(), v.clone())));
                out
            })
            .collect(),
        "chooseBranch" => if run.param("output").is_str("input2") {
            second
        } else {
            first
        }
        .clone(),
        _ => return fail(ErrorKind::Node, format!("unknown merge mode {mode}")),
    };
    Ok(NodeResult::Outputs(vec![merged]))
}

fn wait(run: &NodeRun<'_>) -> Result<NodeResult> {
    let ms = run.number("seconds", 0)? * 1000.0;
    Ok(NodeResult::Effect(obj([
        ("type", "wait".into()),
        ("ms", Val::Num(if ms >= 0.0 { ms } else { 0.0 })),
    ])))
}

fn respond(run: &NodeRun<'_>) -> Result<NodeResult> {
    let body = if run.param("body").is_str("") {
        items_val(run.items())
    } else {
        run.value("body", 0)?
    };
    let effect: Obj = obj([
        ("type", "respond".into()),
        ("status", Val::Num(run.number("status", 0)?)),
        (
            "contentType",
            Val::Str(to_str(&run.value("contentType", 0)?)),
        ),
        ("body", body),
    ]);
    Ok(NodeResult::Effect(effect))
}

pub static FLOW_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "core.if",
        label: "If",
        group: NodeGroup::Flow,
        description: "Sends each item to \"true\" or \"false\" depending on conditions.",
        inputs: 1,
        outputs: Some(&["true", "false"]),
        params: CONDITION_PARAMS,
        run: if_node,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.filter",
        label: "Filter",
        group: NodeGroup::Flow,
        description: "Keeps only the items that match the conditions.",
        inputs: 1,
        outputs: Some(&["kept"]),
        params: CONDITION_PARAMS,
        run: filter,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.switch",
        label: "Switch",
        group: NodeGroup::Flow,
        description: "Sends each item to the output of the first rule it matches.",
        inputs: 1,
        outputs: None,
        params: &[
            ParamSpec::new("rules", "Rules", ParamKind::Rules, Default::EmptyList),
            ParamSpec::new(
                "fallback",
                "Fallback output for unmatched items",
                ParamKind::Boolean,
                Default::Bool(false),
            ),
        ],
        run: switch,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.merge",
        label: "Merge",
        group: NodeGroup::Flow,
        description: "Waits for both inputs, then appends them, pairs them by position, or picks one.",
        inputs: 2,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("mode", "Mode", ParamKind::Select, Default::Text("append")).options(&[
                "append",
                "combineByIndex",
                "chooseBranch",
            ]),
            ParamSpec::new(
                "output",
                "Branch to keep",
                ParamKind::Select,
                Default::Text("input1"),
            )
            .options(&["input1", "input2"]),
        ],
        run: merge,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.noop",
        label: "No Operation",
        group: NodeGroup::Flow,
        description: "Passes items through unchanged.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[],
        run: pass_through,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.wait",
        label: "Wait",
        group: NodeGroup::Flow,
        description: "Pauses the execution, then continues with the same items.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[ParamSpec::new(
            "seconds",
            "Seconds",
            ParamKind::Number,
            Default::Number(5.0),
        )],
        run: wait,
        resume: Some(resume_pass_through),
        step: None,
    },
    NodeSpec {
        type_name: "core.respond",
        label: "Respond to Webhook",
        group: NodeGroup::Flow,
        description: "Sends the HTTP response for the webhook that started the run.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "status",
                "Status code",
                ParamKind::Number,
                Default::Number(200.0),
            ),
            ParamSpec::new(
                "contentType",
                "Content type",
                ParamKind::Text,
                Default::Text("application/json"),
            ),
            ParamSpec::new("body", "Body", ParamKind::Json, Default::Text(""))
                .hint("empty sends the incoming items"),
        ],
        run: respond,
        resume: Some(resume_pass_through),
        step: None,
    },
];
