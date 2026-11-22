//! Loop Over Items and Execute Workflow; see `nodes/control.ts`.

use super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj};

fn item_list(v: &Val) -> Vec<Item> {
    match v {
        Val::Arr(list) => list.iter().filter_map(|x| x.as_obj().cloned()).collect(),
        _ => Vec::new(),
    }
}

fn items_val(items: &[Item]) -> Val {
    Val::Arr(items.iter().cloned().map(Val::Obj).collect())
}

/// Hands items to the `loop` output a batch at a time; whatever comes back is
/// collected, and goes out of `done` once no batch is left.
fn run_loop(run: &NodeRun<'_>) -> Result<NodeResult> {
    let size = run.number("batchSize", 0)?.trunc();
    let batch = if size >= 1.0 { size } else { 1.0 };
    let (rest, done) = match &run.memo {
        Val::Obj(memo) => {
            let mut done = item_list(get_key(memo, "done"));
            done.extend(run.items().iter().cloned());
            (item_list(get_key(memo, "rest")), done)
        }
        _ => (run.items().to_vec(), Vec::new()),
    };
    if run.memo.as_obj().is_some() && rest.is_empty() {
        return Ok(NodeResult::OutputsWithMemory(
            vec![done, Vec::new()],
            Val::Null,
        ));
    }
    // The size is a whole number of at least one; beyond the list it takes everything.
    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        clippy::cast_precision_loss
    )]
    let take = if batch >= rest.len() as f64 {
        rest.len()
    } else {
        batch as usize
    };
    let memory = obj([
        ("rest", items_val(&rest[take..])),
        ("done", items_val(&done)),
    ]);
    Ok(NodeResult::OutputsWithMemory(
        vec![Vec::new(), rest[..take].to_vec()],
        Val::Obj(memory),
    ))
}

const RUN_MODES: &[&str] = &["allItems", "eachItem"];

fn call_workflow(run: &NodeRun<'_>) -> Result<NodeResult> {
    let workflow_id = run.text("workflowId", 0)?;
    if workflow_id.is_empty() {
        return fail(ErrorKind::Node, "choose a workflow");
    }
    let mode = run.text("mode", 0)?;
    if !RUN_MODES.contains(&mode.as_str()) {
        return fail(ErrorKind::Node, format!("unknown mode {mode}"));
    }
    let runs: Vec<Val> = if mode == "eachItem" {
        run.items()
            .iter()
            .map(|item| items_val(std::slice::from_ref(item)))
            .collect()
    } else {
        vec![items_val(run.items())]
    };
    Ok(NodeResult::Effect(obj([
        ("type", "workflow".into()),
        ("workflowId", Val::Str(workflow_id)),
        (
            "wait",
            Val::Bool(!matches!(run.param("wait"), Val::Bool(false))),
        ),
        ("runs", Val::Arr(runs)),
    ])))
}

/// The called workflow's output items, one list per call, in order.
fn workflow_results(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    if matches!(run.param("wait"), Val::Bool(false)) {
        return Ok(vec![run.items().to_vec()]);
    }
    let expected = if run.text("mode", 0)? == "eachItem" {
        run.items().len()
    } else {
        1
    };
    match get_key(result, "outputs") {
        Val::Arr(outputs)
            if outputs.len() == expected && outputs.iter().all(|o| o.as_arr().is_some()) =>
        {
            Ok(vec![outputs.iter().flat_map(item_list).collect()])
        }
        _ => fail(
            ErrorKind::Node,
            format!("expected {expected} workflow results"),
        ),
    }
}

pub static CONTROL_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "core.loop",
        label: "Loop Over Items",
        group: NodeGroup::Flow,
        description: "Sends items through the “loop” branch a batch at a time; connect its end back here. Then outputs everything on “done”.",
        inputs: 1,
        outputs: Some(&["done", "loop"]),
        params: &[ParamSpec::new(
            "batchSize",
            "Batch size",
            ParamKind::Number,
            Default::Number(1.0),
        )],
        run: run_loop,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.executeWorkflow",
        label: "Execute Workflow",
        group: NodeGroup::Flow,
        description: "Runs another workflow (it starts at its “When Called by a Workflow” trigger) and outputs what it returned.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "workflowId",
                "Workflow",
                ParamKind::Workflow,
                Default::Text(""),
            ),
            ParamSpec::new(
                "mode",
                "Run it",
                ParamKind::Select,
                Default::Text("allItems"),
            )
            .options(RUN_MODES),
            ParamSpec::new(
                "wait",
                "Wait for it to finish",
                ParamKind::Boolean,
                Default::Bool(true),
            ),
        ],
        run: call_workflow,
        resume: Some(workflow_results),
        step: None,
    },
];
