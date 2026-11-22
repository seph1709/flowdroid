//! Nodes that reshape items: no side effects, outputs computed immediately.

use std::cmp::Ordering;
use std::collections::HashSet;

use super::spec::{Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::expression::render;
use crate::value::{
    Obj, Val, compare_strings, get_key, get_path, items_val, last_segment, set_path, stringify,
    to_int, to_str,
};

fn set_fields(run: &NodeRun<'_>) -> Result<NodeResult> {
    let fields = run.rows("fields")?;
    let keep_only_set = run.param("keepOnlySet").is_true();
    let mut out_items = Vec::with_capacity(run.items().len());
    for (i, item) in run.items().iter().enumerate() {
        let scope = run.scope(i);
        let mut out = if keep_only_set {
            Obj::new()
        } else {
            item.clone()
        };
        for field in &fields {
            let name = to_str(&render(get_key(field, "name"), &scope)?);
            if name.is_empty() {
                return fail(ErrorKind::Node, "field name is required");
            }
            set_path(&mut out, &name, render(get_key(field, "value"), &scope)?);
        }
        out_items.push(out);
    }
    Ok(NodeResult::Outputs(vec![out_items]))
}

fn required_field(run: &NodeRun<'_>) -> Result<String> {
    let field = run.text("field", 0)?;
    if field.is_empty() {
        return fail(ErrorKind::Node, "field is required");
    }
    Ok(field)
}

fn split_out(run: &NodeRun<'_>) -> Result<NodeResult> {
    let field = required_field(run)?;
    let key = last_segment(&field);
    let mut out = Vec::new();
    for item in run.items() {
        let Val::Arr(list) = get_path(&Val::Obj(item.clone()), &field).clone() else {
            return fail(ErrorKind::Node, format!("field '{field}' is not a list"));
        };
        out.extend(list.into_iter().map(|entry| match entry {
            Val::Obj(o) => o,
            other => Obj::from([(key.to_owned(), other)]),
        }));
    }
    Ok(NodeResult::Outputs(vec![out]))
}

fn aggregate(run: &NodeRun<'_>) -> Result<NodeResult> {
    let field = run.text("field", 0)?;
    let mut out = Obj::new();
    if field.is_empty() {
        out.insert("items".into(), items_val(run.items()));
    } else {
        let values = run
            .items()
            .iter()
            .map(|item| path_of(item, &field))
            .collect();
        set_path(&mut out, last_segment(&field), Val::Arr(values));
    }
    Ok(NodeResult::Outputs(vec![vec![out]]))
}

fn limit(run: &NodeRun<'_>) -> Result<NodeResult> {
    let max = to_int(&render(run.param("max"), &run.scope(0))?).max(0.0);
    let items = run.items();
    let count = if max >= items.len() as f64 {
        items.len()
    } else {
        max as usize
    };
    Ok(NodeResult::Outputs(vec![items[..count].to_vec()]))
}

fn path_of(item: &Item, path: &str) -> Val {
    let root = Val::Obj(item.clone());
    get_path(&root, path).clone()
}

/// Total order: numbers (not NaN) first, then strings, then everything else by its text.
fn compare_values(a: &Val, b: &Val) -> Ordering {
    let rank = |v: &Val| match v {
        Val::Num(n) if !n.is_nan() => 0,
        Val::Str(_) => 1,
        _ => 2,
    };
    match (a, b) {
        (Val::Num(x), Val::Num(y)) if rank(a) == 0 && rank(b) == 0 => {
            x.partial_cmp(y).unwrap_or(Ordering::Equal)
        }
        _ if rank(a) != rank(b) => rank(a).cmp(&rank(b)),
        _ => compare_strings(&to_str(a), &to_str(b)),
    }
}

fn sort(run: &NodeRun<'_>) -> Result<NodeResult> {
    let field = required_field(run)?;
    let descending = run.param("order").is_str("desc");
    let mut keyed: Vec<(Val, Item)> = run
        .items()
        .iter()
        .map(|item| (path_of(item, &field), item.clone()))
        .collect();
    keyed.sort_by(|(a, _), (b, _)| {
        let order = compare_values(a, b);
        if descending { order.reverse() } else { order }
    });
    Ok(NodeResult::Outputs(vec![
        keyed.into_iter().map(|(_, item)| item).collect(),
    ]))
}

fn remove_duplicates(run: &NodeRun<'_>) -> Result<NodeResult> {
    let field = run.text("field", 0)?;
    let mut seen = HashSet::new();
    let kept = run
        .items()
        .iter()
        .filter(|item| {
            let key = if field.is_empty() {
                stringify(&Val::Obj((*item).clone()))
            } else {
                stringify(&path_of(item, &field))
            };
            seen.insert(key)
        })
        .cloned()
        .collect();
    Ok(NodeResult::Outputs(vec![kept]))
}

const fn field_param(label: &'static str, hint: &'static str) -> ParamSpec {
    ParamSpec::new("field", label, ParamKind::Text, Default::Text("")).hint(hint)
}

pub static DATA_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "core.set",
        label: "Edit Fields (Set)",
        group: NodeGroup::Data,
        description: "Adds or changes fields on every item. Names may be dotted paths.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new("fields", "Fields", ParamKind::Fields, Default::EmptyList),
            ParamSpec::new(
                "keepOnlySet",
                "Keep only these fields",
                ParamKind::Boolean,
                Default::Bool(false),
            ),
        ],
        run: set_fields,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.splitOut",
        label: "Split Out",
        group: NodeGroup::Data,
        description: "Turns a list field into one item per entry.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[field_param("List field", "e.g. data.users")],
        run: split_out,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.aggregate",
        label: "Aggregate",
        group: NodeGroup::Data,
        description: "Collects all items (or one field of each) into a single item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[field_param(
            "Field to collect",
            "empty collects whole items",
        )],
        run: aggregate,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.sort",
        label: "Sort",
        group: NodeGroup::Data,
        description: "Sorts items by a field.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            field_param("Sort by field", "e.g. price"),
            ParamSpec::new("order", "Order", ParamKind::Select, Default::Text("asc"))
                .options(&["asc", "desc"]),
        ],
        run: sort,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.removeDuplicates",
        label: "Remove Duplicates",
        group: NodeGroup::Data,
        description: "Keeps the first item for each distinct value of a field (or of the whole item).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[field_param("Compare field", "empty compares whole items")],
        run: remove_duplicates,
        resume: None,
        step: None,
    },
    NodeSpec {
        type_name: "core.limit",
        label: "Limit",
        group: NodeGroup::Data,
        description: "Keeps only the first N items.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[ParamSpec::new(
            "max",
            "Max items",
            ParamKind::Number,
            Default::Number(1.0),
        )],
        run: limit,
        resume: None,
        step: None,
    },
];
