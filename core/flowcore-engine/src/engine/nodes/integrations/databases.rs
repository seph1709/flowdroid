//! Supabase, Airtable, Notion and the on-phone table store; see `integrations/databases.ts`.

use super::super::spec::{
    Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec, resume_pass_through,
};
use super::api::{
    ApiCall, api_request, api_resume, as_items, credential_param, enc, json_param, per_item,
    required,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::expression::render;
use crate::value::{Obj, Val, format_number, get_key, obj, to_int, to_template_str};

/// Equality filters from a key/value list, rendered for one item.
fn filters(run: &NodeRun<'_>, index: usize) -> Result<Vec<(String, String)>> {
    let scope = run.scope(index);
    let mut out = Vec::new();
    for row in run.rows("filters")? {
        let name = to_template_str(&render(get_key(row, "name"), &scope)?);
        let value = to_template_str(&render(get_key(row, "value"), &scope)?);
        if !name.is_empty() {
            out.push((name, value));
        }
    }
    Ok(out)
}

fn limit(run: &NodeRun<'_>, index: usize) -> Result<f64> {
    Ok(to_int(&run.value("limit", index)?).max(1.0))
}

// ---------- Supabase (PostgREST) ----------

fn supabase(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let table = required(run, "table", index, "table")?;
    let operation = run.text("operation", index)?;
    let filters = filters(run, index)?;
    let filter_parts: Vec<String> = filters
        .iter()
        .map(|(name, value)| format!("{}=eq.{}", enc(name), enc(value)))
        .collect();
    let base = format!("{{cred:url}}/rest/v1/{}", enc(&table));
    let query = |parts: &[String]| {
        if parts.is_empty() {
            String::new()
        } else {
            format!("?{}", parts.join("&"))
        }
    };
    if (operation == "update" || operation == "delete") && filter_parts.is_empty() {
        let verb = if operation == "update" {
            "updating"
        } else {
            "deleting"
        };
        return fail(
            ErrorKind::Node,
            format!("add at least one filter before {verb} rows"),
        );
    }
    let auth = |call: ApiCall| {
        call.header("apikey", "{cred:serviceKey}")
            .header("Authorization", "Bearer {cred:serviceKey}")
    };
    let call = match operation.as_str() {
        "select" => {
            let mut parts = vec!["select=*".to_owned()];
            parts.extend(filter_parts);
            parts.push(format!("limit={}", format_number(limit(run, index)?)));
            auth(ApiCall::new("GET", format!("{base}{}", query(&parts))))
        }
        "insert" => auth(ApiCall::new("POST", base))
            .header("Prefer", "return=representation")
            .body(json_param(run, "row", index)?),
        "update" => auth(ApiCall::new(
            "PATCH",
            format!("{base}{}", query(&filter_parts)),
        ))
        .header("Prefer", "return=representation")
        .body(json_param(run, "row", index)?),
        "delete" => auth(ApiCall::new(
            "DELETE",
            format!("{base}{}", query(&filter_parts)),
        ))
        .header("Prefer", "return=representation"),
        _ => return fail(ErrorKind::Node, format!("unknown operation {operation}")),
    };
    api_request(run, call)
}

// ---------- Airtable ----------

fn airtable(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let base_id = required(run, "baseId", index, "base ID")?;
    let table = required(run, "table", index, "table")?;
    let base = format!(
        "https://api.airtable.com/v0/{}/{}",
        enc(&base_id),
        enc(&table)
    );
    let auth = |call: ApiCall| call.header("Authorization", "Bearer {cred:token}");
    let operation = run.text("operation", index)?;
    let call = match operation.as_str() {
        "list" => {
            let mut parts = vec![format!("maxRecords={}", format_number(limit(run, index)?))];
            let formula = run.text("filterFormula", index)?;
            if !formula.is_empty() {
                parts.push(format!("filterByFormula={}", enc(&formula)));
            }
            auth(ApiCall::new("GET", format!("{base}?{}", parts.join("&"))))
        }
        "create" => auth(ApiCall::new("POST", base)).body(Val::Obj(obj([(
            "fields",
            json_param(run, "fields", index)?,
        )]))),
        "update" => {
            let id = required(run, "recordId", index, "record ID")?;
            auth(ApiCall::new("PATCH", format!("{base}/{}", enc(&id)))).body(Val::Obj(obj([(
                "fields",
                json_param(run, "fields", index)?,
            )])))
        }
        _ => return fail(ErrorKind::Node, format!("unknown operation {operation}")),
    };
    api_request(run, call)
}

/// The value at [key] when the body is an object holding a list there; otherwise the body itself, as one entry.
fn list_or_self(body: Val, key: &str) -> Vec<Val> {
    match body {
        Val::Obj(mut o) if matches!(o.get(key), Some(Val::Arr(_))) => match o.swap_remove(key) {
            Some(Val::Arr(list)) => list,
            _ => Vec::new(),
        },
        other => vec![other],
    }
}

/// Airtable records as items: the record id and time next to its fields.
fn airtable_items(body: Val) -> Vec<Item> {
    list_or_self(body, "records")
        .into_iter()
        .map(|record| {
            let r = match record {
                Val::Obj(o) => o,
                _ => Obj::new(),
            };
            let mut item = obj([
                ("id", get_key(&r, "id").clone()),
                ("createdTime", get_key(&r, "createdTime").clone()),
            ]);
            if let Val::Obj(fields) = get_key(&r, "fields") {
                item.extend(fields.iter().map(|(k, v)| (k.clone(), v.clone())));
            }
            item
        })
        .collect()
}

// ---------- Notion ----------

fn notion(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let database = required(run, "databaseId", index, "database ID")?;
    let auth = |call: ApiCall| {
        call.header("Authorization", "Bearer {cred:token}")
            .header("Notion-Version", "2022-06-28")
    };
    let operation = run.text("operation", index)?;
    let call = match operation.as_str() {
        "query" => {
            let filter = json_param(run, "filter", index)?;
            let mut body = obj([("page_size", Val::Num(limit(run, index)?.min(100.0)))]);
            if matches!(filter, Val::Obj(_)) {
                body.insert("filter".into(), filter);
            }
            auth(ApiCall::new(
                "POST",
                format!(
                    "https://api.notion.com/v1/databases/{}/query",
                    enc(&database)
                ),
            ))
            .body(Val::Obj(body))
        }
        "create" => {
            auth(ApiCall::new("POST", "https://api.notion.com/v1/pages")).body(Val::Obj(obj([
                (
                    "parent",
                    Val::Obj(obj([("database_id", Val::Str(database))])),
                ),
                ("properties", json_param(run, "properties", index)?),
            ])))
        }
        _ => return fail(ErrorKind::Node, format!("unknown operation {operation}")),
    };
    api_request(run, call)
}

fn notion_items(body: Val) -> Vec<Item> {
    list_or_self(body, "results")
        .into_iter()
        .map(|page| {
            let p = match page {
                Val::Obj(o) => o,
                _ => Obj::new(),
            };
            obj([
                ("id", get_key(&p, "id").clone()),
                ("url", get_key(&p, "url").clone()),
                ("properties", get_key(&p, "properties").clone()),
            ])
        })
        .collect()
}

// ---------- Table store on the phone ----------

fn table_effect(run: &NodeRun<'_>) -> Result<NodeResult> {
    let operation = run.text("operation", 0)?;
    if !["insert", "find", "update", "delete"].contains(&operation.as_str()) {
        return fail(ErrorKind::Node, format!("unknown operation {operation}"));
    }
    let table = required(run, "table", 0, "table")?;
    let mut requests = Vec::new();
    for i in 0..run.items().len() {
        let where_: Obj = filters(run, i)?
            .into_iter()
            .map(|(k, v)| (k, Val::Str(v)))
            .collect();
        let row = if operation == "insert" || operation == "update" {
            json_param(run, "row", i)?
        } else {
            Val::Null
        };
        if !row.is_null() && !matches!(row, Val::Obj(_)) {
            return fail(ErrorKind::Node, "row must be an object");
        }
        requests.push(Val::Obj(obj([
            ("where", Val::Obj(where_)),
            ("row", row),
            ("limit", Val::Num(limit(run, i)?)),
        ])));
    }
    Ok(NodeResult::Effect(obj([
        ("type", "table".into()),
        ("table", Val::Str(table)),
        ("operation", Val::Str(operation)),
        ("requests", Val::Arr(requests)),
    ])))
}

fn table_items(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    if let Val::Str(error) = get_key(result, "error") {
        return fail(ErrorKind::Node, error.clone());
    }
    match get_key(result, "rows") {
        Val::Arr(rows) => Ok(vec![
            rows.iter().filter_map(|r| r.as_obj().cloned()).collect(),
        ]),
        _ => resume_pass_through(run, result),
    }
}

fn run_supabase(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| supabase(run, i))
}
fn resume_supabase(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Supabase", |body, _| Ok(as_items(body)))
}
fn run_airtable(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| airtable(run, i))
}
fn resume_airtable(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Airtable", |body, _| Ok(airtable_items(body)))
}
fn run_notion(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| notion(run, i))
}
fn resume_notion(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Notion", |body, _| Ok(notion_items(body)))
}

const FILTERS: ParamSpec = ParamSpec::new(
    "filters",
    "Where (column equals value)",
    ParamKind::KeyValues,
    Default::EmptyList,
);

pub static DATABASE_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "db.supabase",
        label: "Supabase",
        group: NodeGroup::Database,
        description: "Reads, inserts, updates or deletes rows in a Supabase table.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            credential_param(&["supabase"]),
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("select"),
            )
            .options(&["select", "insert", "update", "delete"]),
            ParamSpec::new("table", "Table", ParamKind::Text, Default::Text("")),
            FILTERS,
            ParamSpec::new(
                "row",
                "Row (insert or update)",
                ParamKind::Json,
                Default::Text("{{ $json }}"),
            ),
            ParamSpec::new(
                "limit",
                "Max rows",
                ParamKind::Number,
                Default::Number(100.0),
            ),
        ],
        run: run_supabase,
        resume: Some(resume_supabase),
        step: None,
    },
    NodeSpec {
        type_name: "db.airtable",
        label: "Airtable",
        group: NodeGroup::Database,
        description: "Lists, creates or updates records in an Airtable table.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            credential_param(&["airtable"]),
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("list"),
            )
            .options(&["list", "create", "update"]),
            ParamSpec::new("baseId", "Base ID", ParamKind::Text, Default::Text(""))
                .hint("starts with app"),
            ParamSpec::new("table", "Table", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "recordId",
                "Record ID (update)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "fields",
                "Fields (create or update)",
                ParamKind::Json,
                Default::Text("{{ $json }}"),
            ),
            ParamSpec::new(
                "filterFormula",
                "Filter formula (list)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "limit",
                "Max records",
                ParamKind::Number,
                Default::Number(100.0),
            ),
        ],
        run: run_airtable,
        resume: Some(resume_airtable),
        step: None,
    },
    NodeSpec {
        type_name: "db.notion",
        label: "Notion",
        group: NodeGroup::Database,
        description: "Queries a Notion database or adds a page to it.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            credential_param(&["notion"]),
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("query"),
            )
            .options(&["query", "create"]),
            ParamSpec::new(
                "databaseId",
                "Database ID",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "filter",
                "Filter (query, Notion JSON)",
                ParamKind::Json,
                Default::Text(""),
            ),
            ParamSpec::new(
                "properties",
                "Properties (create, Notion JSON)",
                ParamKind::Json,
                Default::Text(""),
            ),
            ParamSpec::new(
                "limit",
                "Max pages",
                ParamKind::Number,
                Default::Number(50.0),
            ),
        ],
        run: run_notion,
        resume: Some(resume_notion),
        step: None,
    },
    NodeSpec {
        type_name: "db.table",
        label: "Phone Table",
        group: NodeGroup::Database,
        description: "Stores rows on this phone: insert, find, update or delete, no account needed.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("insert"),
            )
            .options(&["insert", "find", "update", "delete"]),
            ParamSpec::new(
                "table",
                "Table name",
                ParamKind::Text,
                Default::Text("notes"),
            ),
            FILTERS,
            ParamSpec::new(
                "row",
                "Row (insert or update)",
                ParamKind::Json,
                Default::Text("{{ $json }}"),
            ),
            ParamSpec::new(
                "limit",
                "Max rows (find)",
                ParamKind::Number,
                Default::Number(100.0),
            ),
        ],
        run: table_effect,
        resume: Some(table_items),
        step: None,
    },
];
