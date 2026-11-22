//! Runs a workflow as a deterministic state machine.
//!
//! Nodes run breadth-first from the trigger. A node with several inputs
//! (Merge) waits until every connected input has delivered, or until nothing
//! else is left to run. When a node needs a side effect, the run pauses with
//! status `waiting`; the host performs `pending.effect` and resumes.

use super::context::{Item, base_context};
use super::nodes::spec::{NodeResult, NodeRun, NodeSpec, StepResult};
use super::nodes::{params_with_defaults, spec_for};
use super::state::{ExecutionState, Pending, Status, Task};
use super::workflow::{Workflow, WorkflowNode};
use crate::errors::{ErrorKind, Result, fail};
use crate::time::iso_string;
use crate::value::{Obj, Val, format_number, obj};

/// Guards against workflows that loop forever.
pub const MAX_STEPS: u32 = 5000;

struct Ready<'a> {
    node: &'a WorkflowNode,
    inputs: Vec<Vec<Item>>,
}

pub fn start(
    wf: &Workflow,
    trigger_id: &str,
    items: Vec<Item>,
    now: i64,
) -> Result<ExecutionState> {
    let Some(trigger) = wf.node(trigger_id) else {
        return fail(
            ErrorKind::Input,
            format!("unknown trigger node {trigger_id}"),
        );
    };
    let mut state = ExecutionState::new(now as f64);
    state.steps = 1.0;
    let pinned = if wf.use_pinned {
        trigger.pinned.clone()
    } else {
        None
    };
    complete(
        wf,
        &mut state,
        trigger,
        &[pinned.unwrap_or(items)],
        None,
        now,
    );
    drain(wf, &mut state, now);
    Ok(state)
}

pub fn resume(
    wf: &Workflow,
    mut state: ExecutionState,
    result: &Obj,
    now: i64,
) -> Result<ExecutionState> {
    let not_waiting = || {
        fail(
            ErrorKind::Input,
            "execution is not waiting for an effect result",
        )
    };
    let Some(pending) = state.pending.take() else {
        return not_waiting();
    };
    let Some(node) = wf.node(&pending.node) else {
        return not_waiting();
    };
    let Some(spec) = spec_for(&node.type_name).filter(|s| s.step.is_some() || s.resume.is_some())
    else {
        return fail(
            ErrorKind::Input,
            format!("node {} does not take effect results", node.name),
        );
    };
    state.status = Status::Running;
    if pending.retry {
        // The wait before another try is over: run the node again from the start.
        let ready = Ready {
            node,
            inputs: pending.inputs,
        };
        execute(wf, &mut state, &ready, now, pending.attempt);
    } else {
        let run = make_run(
            wf,
            &state,
            node,
            spec,
            &pending.inputs,
            now,
            pending.memo.clone(),
        );
        let stepped = match (spec.step, spec.resume) {
            (Some(step), _) => step(&run, result),
            (None, Some(resume)) => resume(&run, result).map(StepResult::Outputs),
            (None, None) => unreachable!("checked above"),
        };
        match stepped {
            Ok(StepResult::Effect(effect, memo)) => {
                state.pending = Some(Pending {
                    effect,
                    memo,
                    ..pending
                });
                state.status = Status::Waiting;
            }
            Ok(StepResult::Outputs(outputs)) => complete(wf, &mut state, node, &outputs, None, now),
            Err(e) => {
                let message = e.to_string();
                if node.retry_on_fail && pending.attempt < node.max_tries {
                    let reason = format!(
                        "retry {} of {}: {message}",
                        format_number(pending.attempt + 1.0),
                        format_number(node.max_tries)
                    );
                    state.pending = Some(Pending {
                        node: node.id.clone(),
                        inputs: pending.inputs,
                        effect: obj([
                            ("type", "wait".into()),
                            ("ms", Val::Num(node.wait_between_tries)),
                            ("reason", reason.into()),
                        ]),
                        memo: Val::Null,
                        attempt: pending.attempt + 1.0,
                        retry: true,
                    });
                    state.status = Status::Waiting;
                } else {
                    fail_node(wf, &mut state, node, &message, now);
                }
            }
        }
    }
    drain(wf, &mut state, now);
    Ok(state)
}

fn drain(wf: &Workflow, state: &mut ExecutionState, now: i64) {
    while state.status == Status::Running {
        match next_ready(wf, state) {
            None => {
                state.status = Status::Success;
                state.finished_at = Some(now as f64);
            }
            Some(_) if state.steps >= f64::from(MAX_STEPS) => {
                state.status = Status::Error;
                state.error = Some(format!("execution stopped after {MAX_STEPS} node runs"));
                state.finished_at = Some(now as f64);
            }
            Some(ready) => execute(wf, state, &ready, now, 1.0),
        }
    }
}

fn next_ready<'a>(wf: &'a Workflow, state: &mut ExecutionState) -> Option<Ready<'a>> {
    while let Some(task) = state.queue.pop_front() {
        let Some(node) = wf.node(&task.node) else {
            continue;
        };
        match spec_for(&node.type_name) {
            Some(spec) if spec.inputs >= 2 => {
                if let Some(inputs) = collect(wf, state, node, spec, task) {
                    return Some(Ready { node, inputs });
                }
            }
            _ => {
                return Some(Ready {
                    node,
                    inputs: vec![task.items],
                });
            }
        }
    }
    flush_waiting(wf, state)
}

/// Adds a task to its node's input slots; returns all inputs once every connected one has arrived.
fn collect(
    wf: &Workflow,
    state: &mut ExecutionState,
    node: &WorkflowNode,
    spec: &NodeSpec,
    task: Task,
) -> Option<Vec<Vec<Item>>> {
    let mut slots = match state.waiting.get(&node.id) {
        Some(Val::Arr(slots)) => slots.clone(),
        _ => Vec::new(),
    };
    if slots.len() <= task.input {
        slots.resize(task.input + 1, Val::Null);
    }
    let mut merged = match &slots[task.input] {
        Val::Arr(previous) => previous.clone(),
        _ => Vec::new(),
    };
    merged.extend(task.items.into_iter().map(Val::Obj));
    slots[task.input] = Val::Arr(merged);
    let complete = wf
        .connected_inputs(&node.id)
        .iter()
        .all(|&i| slots.get(i).is_some_and(|s| !s.is_null()));
    if complete {
        state.waiting.shift_remove(&node.id);
        Some(to_inputs(&slots, spec.inputs))
    } else {
        state.waiting.insert(node.id.clone(), Val::Arr(slots));
        None
    }
}

/// With nothing else to run, the first waiting node runs with what it has.
fn flush_waiting<'a>(wf: &'a Workflow, state: &mut ExecutionState) -> Option<Ready<'a>> {
    let node = wf
        .nodes
        .iter()
        .find(|n| state.waiting.contains_key(&n.id))?;
    let stored = state.waiting.shift_remove(&node.id);
    let slots = match stored {
        Some(Val::Arr(slots)) => slots,
        _ => Vec::new(),
    };
    let count = spec_for(&node.type_name).map_or(1, |s| s.inputs);
    Some(Ready {
        node,
        inputs: to_inputs(&slots, count),
    })
}

fn to_inputs(slots: &[Val], count: usize) -> Vec<Vec<Item>> {
    (0..count.max(slots.len()))
        .map(|i| match slots.get(i) {
            Some(Val::Arr(list)) => list.iter().filter_map(|v| v.as_obj().cloned()).collect(),
            _ => Vec::new(),
        })
        .collect()
}

fn execute(wf: &Workflow, state: &mut ExecutionState, ready: &Ready<'_>, now: i64, attempt: f64) {
    let Ready { node, inputs } = ready;
    state.steps += 1.0;
    if node.disabled {
        complete(wf, state, node, &[inputs.concat()], None, now);
        return;
    }
    if let (true, Some(pinned)) = (wf.use_pinned, &node.pinned) {
        complete(wf, state, node, std::slice::from_ref(pinned), None, now);
        return;
    }
    let outcome = match spec_for(&node.type_name) {
        None => fail(
            ErrorKind::Node,
            format!("unknown node type {}", node.type_name),
        ),
        Some(spec) => {
            let memory = state.memory.get(&node.id).cloned().unwrap_or_default();
            (spec.run)(&make_run(wf, state, node, spec, inputs, now, memory))
        }
    };
    let wait = |effect: Obj, memo: Val, state: &mut ExecutionState| {
        state.pending = Some(Pending {
            node: node.id.clone(),
            inputs: inputs.clone(),
            effect,
            memo,
            attempt,
            retry: false,
        });
        state.status = Status::Waiting;
    };
    match outcome {
        Ok(NodeResult::Effect(effect)) => wait(effect, Val::Null, state),
        Ok(NodeResult::EffectWithMemo(effect, memo)) => wait(effect, memo, state),
        Ok(NodeResult::Outputs(outputs)) => complete(wf, state, node, &outputs, None, now),
        Ok(NodeResult::OutputsWithMemory(outputs, memory)) => {
            remember(state, &node.id, memory);
            complete(wf, state, node, &outputs, None, now);
        }
        Err(e) => fail_node(wf, state, node, &e.to_string(), now),
    }
}

/// Keeps [memory] for the node's next run; null forgets it.
fn remember(state: &mut ExecutionState, node_id: &str, memory: Val) {
    if memory.is_null() {
        state.memory.shift_remove(node_id);
    } else {
        state.memory.insert(node_id.to_owned(), memory);
    }
}

fn make_run<'a>(
    wf: &Workflow,
    state: &ExecutionState,
    node: &'a WorkflowNode,
    spec: &NodeSpec,
    inputs: &'a [Vec<Item>],
    now: i64,
    memo: Val,
) -> NodeRun<'a> {
    let items = inputs.first().map_or(&[][..], Vec::as_slice);
    NodeRun {
        node,
        params: params_with_defaults(spec, node),
        inputs,
        base: base_context(wf, &state.last, items, iso_string(now)),
        memo,
    }
}

fn run_record(node: &WorkflowNode, now: i64, error: Option<&str>, outputs: &[Vec<Item>]) -> Val {
    let output = Val::Arr(
        outputs
            .iter()
            .map(|items| Val::Arr(items.iter().cloned().map(Val::Obj).collect()))
            .collect(),
    );
    Val::Obj(obj([
        ("node", node.id.as_str().into()),
        ("name", node.name.as_str().into()),
        ("at", Val::Num(now as f64)),
        ("error", error.into()),
        ("output", output),
    ]))
}

/// Records a node's outputs and queues every connected node that received items.
fn complete(
    wf: &Workflow,
    state: &mut ExecutionState,
    node: &WorkflowNode,
    outputs: &[Vec<Item>],
    error: Option<&str>,
    now: i64,
) {
    state.runs.push(run_record(node, now, error, outputs));
    let flat: Vec<Val> = outputs.iter().flatten().cloned().map(Val::Obj).collect();
    state.last.insert(node.name.clone(), Val::Arr(flat));
    for c in wf.outgoing(&node.id) {
        let items = outputs.get(c.output).cloned().unwrap_or_default();
        if !items.is_empty() {
            state.queue.push_back(Task {
                node: c.to.clone(),
                input: c.input,
                items,
            });
        }
    }
}

/// With "continue on fail", the error becomes an item; otherwise the execution stops.
fn fail_node(
    wf: &Workflow,
    state: &mut ExecutionState,
    node: &WorkflowNode,
    message: &str,
    now: i64,
) {
    if node.continue_on_fail {
        let outputs = vec![vec![obj([("error", Val::from(message))])]];
        complete(wf, state, node, &outputs, Some(message), now);
        return;
    }
    state.runs.push(run_record(node, now, Some(message), &[]));
    state.status = Status::Error;
    state.error = Some(format!("{}: {message}", node.name));
    state.finished_at = Some(now as f64);
}
