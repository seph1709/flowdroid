//! Knowledge base (RAG) nodes; see `integrations/knowledge.ts`. The host does the
//! chunking, embedding, storage and ranking.

use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, check_effect_error,
    resume_pass_through, with_field,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj, to_num};

/// `local` ranks by words on the phone (no key); the others compare meaning with embeddings.
pub const EMBEDDERS: &[&str] = &["local", "openai", "gemini", "openaiCompatible"];
const INFO_OPERATIONS: &[&str] = &["collections", "sources", "deleteSource", "clear"];

/// JavaScript's `Math.round`: halves go up.
fn js_round(x: f64) -> f64 {
    (x + 0.5).floor()
}

/// Text that isn't a number counts as 0.
fn finite_or_zero(x: f64) -> f64 {
    if x.is_finite() { x } else { 0.0 }
}

fn collection_of(run: &NodeRun<'_>) -> Result<String> {
    let name = run.text("collection", 0)?.trim().to_string();
    if name.is_empty() {
        return fail(ErrorKind::Node, "knowledge base name is required");
    }
    Ok(name)
}

fn add_effect(run: &NodeRun<'_>) -> Result<NodeResult> {
    let embedder = run.text("embedder", 0)?;
    if !EMBEDDERS.contains(&embedder.as_str()) {
        return fail(ErrorKind::Node, format!("unknown search kind {embedder}"));
    }
    let mut effect = obj([
        ("type", "knowledge".into()),
        ("op", "add".into()),
        ("collection", Val::Str(collection_of(run)?)),
        ("embedder", Val::Str(embedder.clone())),
    ]);
    if embedder != "local" {
        let credential = run.text("credential", 0)?;
        if credential.is_empty() {
            return fail(ErrorKind::Node, "choose a credential for the embeddings");
        }
        effect.insert("credential".into(), Val::Str(credential));
        let model = run.text("model", 0)?;
        if !model.is_empty() {
            effect.insert("model".into(), Val::Str(model));
        }
    }
    let size = js_round(to_num(&run.value("chunkSize", 0)?));
    let chunk_size = (if size > 0.0 { size } else { 800.0 }).clamp(100.0, 8000.0);
    let overlap = finite_or_zero(js_round(to_num(&run.value("overlap", 0)?)));
    effect.insert("chunkSize".into(), Val::Num(chunk_size));
    effect.insert(
        "overlap".into(),
        Val::Num(overlap.max(0.0).min((chunk_size / 2.0).floor())),
    );
    let mut documents = Vec::new();
    for (i, item) in run.items().iter().enumerate() {
        let text = run.text("text", i)?;
        // Saving nothing silently hides a wrong field (e.g. a shared file's text is in fileText).
        if text.trim().is_empty() {
            return fail(
                ErrorKind::Node,
                format!("nothing to add: Text is empty (item {})", i + 1),
            );
        }
        documents.push(Val::Obj(obj([
            ("text", Val::Str(text)),
            ("source", Val::Str(run.text("source", i)?)),
            ("metadata", Val::Obj(item.clone())),
        ])));
    }
    effect.insert("documents".into(), Val::Arr(documents));
    Ok(NodeResult::Effect(effect))
}

fn search_effect(run: &NodeRun<'_>) -> Result<NodeResult> {
    let mut effect = obj([
        ("type", "knowledge".into()),
        ("op", "search".into()),
        ("collection", Val::Str(collection_of(run)?)),
    ]);
    let credential = run.text("credential", 0)?;
    if !credential.is_empty() {
        effect.insert("credential".into(), Val::Str(credential));
    }
    let mut queries = Vec::new();
    for i in 0..run.items().len() {
        let k = js_round(to_num(&run.value("topK", i)?));
        queries.push(Val::Obj(obj([
            ("query", Val::Str(run.text("query", i)?)),
            (
                "topK",
                Val::Num((if k > 0.0 { k } else { 4.0 }).clamp(1.0, 50.0)),
            ),
            (
                "minScore",
                Val::Num(finite_or_zero(to_num(&run.value("minScore", i)?)).clamp(0.0, 1.0)),
            ),
        ])));
    }
    effect.insert("queries".into(), Val::Arr(queries));
    Ok(NodeResult::Effect(effect))
}

fn info_effect(run: &NodeRun<'_>) -> Result<NodeResult> {
    let op = run.text("operation", 0)?;
    if !INFO_OPERATIONS.contains(&op.as_str()) {
        return fail(ErrorKind::Node, format!("unknown operation {op}"));
    }
    let mut effect = obj([("type", "knowledge".into()), ("op", Val::Str(op.clone()))]);
    if op != "collections" {
        effect.insert("collection".into(), Val::Str(collection_of(run)?));
    }
    if op == "deleteSource" {
        let source = run.text("source", 0)?;
        if source.is_empty() {
            return fail(ErrorKind::Node, "source is required");
        }
        effect.insert("source".into(), Val::Str(source));
    }
    Ok(NodeResult::Effect(effect))
}

/// Each item gets `knowledge` from the matching entry of the result list.
fn per_item_result(run: &NodeRun<'_>, result: &Obj, key: &str) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    let Val::Arr(list) = get_key(result, key) else {
        return resume_pass_through(run, result);
    };
    let empty = Val::Obj(Obj::new());
    let items = run
        .items()
        .iter()
        .enumerate()
        .map(|(i, item)| {
            let entry = match list.get(i) {
                Some(v @ Val::Obj(_)) => v,
                _ => &empty,
            };
            with_field(std::slice::from_ref(item), "knowledge", entry).remove(0)
        })
        .collect();
    Ok(vec![items])
}

fn added_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    per_item_result(run, result, "added")
}

fn search_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    per_item_result(run, result, "results")
}

fn info_rows(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    check_effect_error(result)?;
    match get_key(result, "rows") {
        Val::Arr(rows) => Ok(vec![
            rows.iter().filter_map(|r| r.as_obj().cloned()).collect(),
        ]),
        _ => resume_pass_through(run, result),
    }
}

const COLLECTION: ParamSpec = ParamSpec::new(
    "collection",
    "Knowledge base",
    ParamKind::Text,
    Default::Text("my-notes"),
)
.hint("a name; created when first used");
const CREDENTIAL: ParamSpec = ParamSpec::new(
    "credential",
    "Credential",
    ParamKind::Credential,
    Default::Text(""),
)
.options(&["openai", "gemini", "openaiCompatible"])
.hint("not needed for Words");

pub static KNOWLEDGE_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "rag.add",
        label: "Add to Knowledge Base",
        group: NodeGroup::Ai,
        description: "Splits text into chunks and saves them on the phone for searching (RAG). Adding the same source again replaces it.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            COLLECTION,
            ParamSpec::new(
                "text",
                "Text",
                ParamKind::Text,
                Default::Text("{{ $json.text }}"),
            ),
            ParamSpec::new("source", "Source", ParamKind::Text, Default::Text(""))
                .hint("title, file or URL; shown with search results"),
            ParamSpec::new(
                "embedder",
                "Search by",
                ParamKind::Select,
                Default::Text("local"),
            )
            .options(EMBEDDERS),
            CREDENTIAL,
            ParamSpec::new(
                "model",
                "Embedding model",
                ParamKind::Text,
                Default::Text(""),
            )
            .hint("empty = the provider\u{2019}s default"),
            ParamSpec::new(
                "chunkSize",
                "Chunk size (characters)",
                ParamKind::Number,
                Default::Number(800.0),
            ),
            ParamSpec::new(
                "overlap",
                "Overlap (characters)",
                ParamKind::Number,
                Default::Number(100.0),
            ),
        ],
        run: add_effect,
        resume: Some(added_items),
        step: None,
    },
    NodeSpec {
        type_name: "rag.search",
        label: "Search Knowledge Base",
        group: NodeGroup::Ai,
        description: "Finds the chunks that best answer a question and outputs them as context for an AI step.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            COLLECTION,
            ParamSpec::new(
                "query",
                "Question",
                ParamKind::Text,
                Default::Text("{{ $json.text }}"),
            ),
            ParamSpec::new("topK", "Results", ParamKind::Number, Default::Number(4.0)),
            ParamSpec::new(
                "minScore",
                "Minimum score",
                ParamKind::Number,
                Default::Number(0.0),
            )
            .hint("0 to 1; 0 keeps every result"),
            CREDENTIAL,
        ],
        run: search_effect,
        resume: Some(search_items),
        step: None,
    },
    NodeSpec {
        type_name: "rag.info",
        label: "Knowledge Base Info",
        group: NodeGroup::Ai,
        description: "Lists knowledge bases or their sources, or deletes a source or a whole knowledge base.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("sources"),
            )
            .options(INFO_OPERATIONS),
            COLLECTION,
            ParamSpec::new(
                "source",
                "Source (delete source)",
                ParamKind::Text,
                Default::Text(""),
            ),
        ],
        run: info_effect,
        resume: Some(info_rows),
        step: None,
    },
];
