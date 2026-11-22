//! RSS Read and Files; see `integrations/files.ts`.

use super::super::file_refs::file_path;
use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
    with_field,
};
use super::api::as_items;
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj};

const FILE_OPERATIONS: &[&str] = &["read", "write", "append", "list", "delete"];

/// One result per item from the host, each turned into items.
fn per_item_results(
    run: &NodeRun<'_>,
    result: &Obj,
    key: &str,
    what: &str,
) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let expected = run.items().len();
    match get_key(result, key) {
        Val::Arr(list) if list.len() == expected => Ok(vec![
            list.iter()
                .flat_map(|entry| match entry {
                    Val::Arr(inner) => inner.iter().filter_map(|x| x.as_obj().cloned()).collect(),
                    other => as_items(other.clone()),
                })
                .collect(),
        ]),
        _ => fail(ErrorKind::Node, format!("expected {expected} {what}")),
    }
}

fn read_feeds(run: &NodeRun<'_>) -> Result<NodeResult> {
    let urls = (0..run.items().len())
        .map(|i| {
            let url = run.text("url", i)?;
            if url.is_empty() {
                return fail(ErrorKind::Node, "feed URL is required");
            }
            Ok(Val::Str(url))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "rss".into()),
        ("urls", Val::Arr(urls)),
    ])))
}

fn feed_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    per_item_results(run, result, "feeds", "feeds")
}

fn file_effect(run: &NodeRun<'_>) -> Result<NodeResult> {
    let operation = run.text("operation", 0)?;
    if !FILE_OPERATIONS.contains(&operation.as_str()) {
        return fail(ErrorKind::Node, format!("unknown operation {operation}"));
    }
    let writes = operation == "write" || operation == "append";
    let requests = (0..run.items().len())
        .map(|i| {
            let path = run.text("path", i)?;
            if path.is_empty() && operation != "list" {
                return fail(ErrorKind::Node, "path is required");
            }
            let content = if writes {
                Val::Str(run.text("content", i)?)
            } else {
                Val::Null
            };
            Ok(Val::Obj(obj([
                ("operation", Val::Str(operation.clone())),
                ("path", Val::Str(path)),
                ("content", content),
            ])))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "file".into()),
        ("requests", Val::Arr(requests)),
    ])))
}

fn file_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    per_item_results(run, result, "results", "file results")
}

fn extract_text(run: &NodeRun<'_>) -> Result<NodeResult> {
    let files = (0..run.items().len())
        .map(|i| {
            let path = file_path(run, "path", i)?;
            if path.is_empty() {
                return fail(ErrorKind::Node, "file is required");
            }
            Ok(Val::Str(path))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(NodeResult::Effect(obj([
        ("type", "extract".into()),
        ("files", Val::Arr(files)),
    ])))
}

/// Extract Text: one result per item, `{ text }` or `{ error }`, stored under the chosen field.
fn extract_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let items = run.items();
    let Val::Arr(list) = get_key(result, "results") else {
        return fail(ErrorKind::Node, format!("expected {} results", items.len()));
    };
    if list.len() != items.len() {
        return fail(ErrorKind::Node, format!("expected {} results", items.len()));
    }
    let field = run.text("field", 0)?;
    let field = if field.is_empty() {
        "text".to_owned()
    } else {
        field
    };
    let mut out = Vec::new();
    for (item, entry) in items.iter().zip(list) {
        let Val::Obj(entry) = entry else {
            return fail(ErrorKind::Node, "no result");
        };
        if let Val::Str(error) = get_key(entry, "error") {
            return fail(ErrorKind::Node, error.clone());
        }
        let text = match get_key(entry, "text") {
            Val::Str(t) => t.clone(),
            _ => String::new(),
        };
        out.push(with_field(std::slice::from_ref(item), &field, &Val::Str(text)).remove(0));
    }
    Ok(vec![out])
}

pub static FILE_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "files.extract",
        label: "Extract Text",
        group: NodeGroup::Data,
        description: "Gets the text out of a file: PDF, Word (.docx), HTML, Markdown, CSV, JSON or plain text.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "path",
                "File",
                ParamKind::Text,
                Default::Text("{{ $json.file.path }}"),
            ),
            ParamSpec::new(
                "field",
                "Put the text in",
                ParamKind::Text,
                Default::Text("text"),
            ),
        ],
        run: extract_text,
        resume: Some(extract_items),
        step: None,
    },
    NodeSpec {
        type_name: "rss.read",
        label: "RSS Read",
        group: NodeGroup::Network,
        description: "Reads an RSS or Atom feed and outputs one item per post.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[ParamSpec::new(
            "url",
            "Feed URL",
            ParamKind::Text,
            Default::Text(""),
        )],
        run: read_feeds,
        resume: Some(feed_items),
        step: None,
    },
    NodeSpec {
        type_name: "files",
        label: "Files",
        group: NodeGroup::System,
        description: "Reads, writes, lists or deletes text files in FlowDroid’s folder (in Ubuntu: /root/files).",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("read"),
            )
            .options(FILE_OPERATIONS),
            ParamSpec::new("path", "Path", ParamKind::Text, Default::Text("notes.txt"))
                .hint("inside FlowDroid’s folder; empty = the folder (list)"),
            ParamSpec::new(
                "content",
                "Content (write, append)",
                ParamKind::Text,
                Default::Text("{{ $json.text }}"),
            ),
        ],
        run: file_effect,
        resume: Some(file_items),
        step: None,
    },
];
