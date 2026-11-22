//! Builds the variables an expression can see while a node runs.

use super::workflow::Workflow;
use crate::value::{Obj, Val, items_val, obj, ordered_entries};

pub type Item = Obj;

/// Variables shared by every item of one node run.
#[must_use]
pub fn base_context(wf: &Workflow, last: &Obj, items: &[Item], now_iso: String) -> Obj {
    let mut nodes = Obj::new();
    for (name, output) in ordered_entries(last) {
        let first = output
            .as_arr()
            .and_then(|list| list.first())
            .cloned()
            .unwrap_or_default();
        nodes.insert(
            name.clone(),
            Val::Obj(obj([("json", first), ("all", output.clone())])),
        );
    }
    obj([
        (
            "$workflow",
            Val::Obj(obj([
                ("id", Val::from(wf.id.as_str())),
                ("name", Val::from(wf.name.as_str())),
            ])),
        ),
        ("$vars", Val::Obj(wf.variables.clone())),
        ("$now", Val::Str(now_iso)),
        ("$node", Val::Obj(nodes)),
        ("$items", items_val(items)),
    ])
}
