//! Google Sheets, Gmail and Calendar; see `integrations/google.ts`.

use super::super::file_refs::{file_path, mime_from_path};
use super::super::spec::{Default, NodeGroup, NodeResult, NodeRun, NodeSpec, ParamKind, ParamSpec};
use super::api::{
    ApiCall, api_effect, api_request, api_resume, as_items, base64_standard, base64_url,
    credential_param, enc, per_item, required, with_extra,
};
use crate::engine::context::Item;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Obj, Val, get_key, obj, ordered_entries, stringify, to_str};

const SHEETS: &str = "https://sheets.googleapis.com/v4/spreadsheets";

fn auth(call: ApiCall) -> ApiCall {
    call.header("Authorization", "Bearer {cred:accessToken}")
}

/// One sheet row from an item's value: lists as they are, objects by their values in order.
fn row_of(v: Val) -> Val {
    match v {
        Val::Arr(_) => v,
        Val::Obj(o) => Val::Arr(
            ordered_entries(&o)
                .into_iter()
                .map(|(_, value)| value.clone())
                .collect(),
        ),
        other => Val::Arr(vec![other]),
    }
}

fn sheets(run: &NodeRun<'_>) -> Result<NodeResult> {
    let id = required(run, "spreadsheetId", 0, "spreadsheet ID")?;
    let range = required(run, "range", 0, "range")?;
    let base = format!("{SHEETS}/{}/values/{}", enc(&id), enc(&range));
    if run.text("operation", 0)? == "append" {
        let values = (0..run.items().len())
            .map(|i| run.value("values", i).map(row_of))
            .collect::<Result<Vec<_>>>()?;
        let call = auth(ApiCall::new(
            "POST",
            format!("{base}:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS"),
        ))
        .body(Val::Obj(obj([("values", Val::Arr(values))])));
        return Ok(api_effect(vec![api_request(run, call)?]));
    }
    Ok(api_effect(vec![api_request(
        run,
        auth(ApiCall::new("GET", base)),
    )?]))
}

/// Read results as items keyed by the header row; append results as one summary item.
fn sheet_items(run: &NodeRun<'_>, body: Val) -> Result<Vec<Item>> {
    if run.text("operation", 0)? == "append" {
        return Ok(as_items(match body {
            Val::Obj(mut o) => o.swap_remove("updates").unwrap_or_default(),
            other => other,
        }));
    }
    let Val::Obj(o) = body else {
        return Ok(Vec::new());
    };
    let Val::Arr(rows) = get_key(&o, "values") else {
        return Ok(Vec::new());
    };
    let Some(first) = rows.first() else {
        return Ok(Vec::new());
    };
    let header: Vec<String> = match first {
        Val::Arr(h) => h.iter().map(to_str).collect(),
        _ => Vec::new(),
    };
    Ok(rows[1..]
        .iter()
        .map(|row| {
            let mut item = Obj::new();
            for (i, name) in header.iter().enumerate() {
                let cell = match row {
                    Val::Arr(cells) => cells.get(i).cloned().unwrap_or_default(),
                    _ => Val::Null,
                };
                item.insert(name.clone(), cell);
            }
            item
        })
        .collect())
}

/// RFC 2047 encoding for a header value that is not plain ASCII.
fn header_text(text: &str) -> String {
    if text.chars().all(|c| (' '..='~').contains(&c)) {
        text.to_owned()
    } else {
        format!("=?UTF-8?B?{}?=", base64_standard(text))
    }
}

fn gmail(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let to = required(run, "to", index, "recipient")?;
    let message = [
        format!("To: {}", header_text(&to)),
        format!("Subject: {}", header_text(&run.text("subject", index)?)),
        "MIME-Version: 1.0".to_owned(),
        "Content-Type: text/plain; charset=UTF-8".to_owned(),
        String::new(),
        run.text("body", index)?,
    ]
    .join("\r\n");
    let call = auth(ApiCall::new(
        "POST",
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
    ))
    .body(Val::Obj(obj([("raw", Val::Str(base64_url(&message)))])));
    api_request(run, call)
}

fn calendar(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let calendar_id = match run.text("calendarId", index)? {
        id if id.is_empty() => "primary".to_owned(),
        id => id,
    };
    let date = |dt: String| Val::Obj(obj([("dateTime", Val::Str(dt))]));
    let mut event = obj([
        (
            "summary",
            Val::Str(required(run, "summary", index, "title")?),
        ),
        ("start", date(required(run, "start", index, "start time")?)),
        ("end", date(required(run, "end", index, "end time")?)),
    ]);
    let description = run.text("description", index)?;
    if !description.is_empty() {
        event.insert("description".into(), Val::Str(description));
    }
    let call = auth(ApiCall::new(
        "POST",
        format!(
            "https://www.googleapis.com/calendar/v3/calendars/{}/events",
            enc(&calendar_id)
        ),
    ))
    .body(Val::Obj(event));
    api_request(run, call)
}

fn resume_sheets(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Google Sheets", |body, _| sheet_items(run, body))
}
fn run_gmail(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| gmail(run, i))
}
fn resume_gmail(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Gmail", |body, _| Ok(as_items(body)))
}
fn run_calendar(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| calendar(run, i))
}
fn resume_calendar(_run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Google Calendar", |body, _| Ok(as_items(body)))
}

const DRIVE: &str = "https://www.googleapis.com/drive/v3/files";
const DRIVE_UPLOAD: &str = "https://www.googleapis.com/upload/drive/v3/files";
const BOUNDARY: &str = "flowdroid-part";
const DRIVE_OPERATIONS: &[&str] = &["list", "upload", "download"];

fn drive_upload(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let file = file_path(run, "file", index)?;
    let name = run.text("name", index)?;
    let file_name = if !file.is_empty() && name.is_empty() {
        file.rsplit('/').next().unwrap_or(&file).to_owned()
    } else {
        required(run, "name", index, "file name")?
    };
    let mut metadata = obj([("name", Val::Str(file_name))]);
    let folder = run.text("folderId", index)?;
    if !folder.is_empty() {
        metadata.insert("parents".into(), Val::Arr(vec![Val::Str(folder)]));
    }
    let mime = run.text("mimeType", index)?;
    if !file.is_empty() {
        // The host builds the multipart body from the metadata and the file's bytes.
        let request = api_request(
            run,
            auth(ApiCall::new(
                "POST",
                format!(
                    "{DRIVE_UPLOAD}?uploadType=multipart&fields={}",
                    enc("id,name,mimeType")
                ),
            )),
        )?;
        let file_mime = if mime.is_empty() || mime == "text/plain" {
            mime_from_path(&file).to_owned()
        } else {
            mime
        };
        return Ok(with_extra(
            request,
            "related",
            Val::Obj(obj([
                ("metadata", Val::Obj(metadata)),
                ("file", Val::Str(file)),
                ("mimeType", Val::Str(file_mime)),
            ])),
        ));
    }
    let body = [
        format!("--{BOUNDARY}"),
        "Content-Type: application/json; charset=UTF-8".to_owned(),
        String::new(),
        stringify(&Val::Obj(metadata)),
        format!("--{BOUNDARY}"),
        format!(
            "Content-Type: {}",
            if mime.is_empty() { "text/plain" } else { &mime }
        ),
        String::new(),
        run.text("content", index)?,
        format!("--{BOUNDARY}--"),
    ]
    .join("\r\n");
    let call = auth(ApiCall::new(
        "POST",
        format!(
            "{DRIVE_UPLOAD}?uploadType=multipart&fields={}",
            enc("id,name,mimeType")
        ),
    ))
    .header(
        "Content-Type",
        &format!("multipart/related; boundary={BOUNDARY}"),
    )
    .body(Val::Str(body));
    api_request(run, call)
}

fn drive(run: &NodeRun<'_>, index: usize) -> Result<Val> {
    let operation = run.text("operation", 0)?;
    match operation.as_str() {
        "list" => {
            let query = run.text("query", index)?;
            let mut parts = vec![
                "pageSize=100".to_owned(),
                format!(
                    "fields={}",
                    enc("files(id,name,mimeType,modifiedTime,size)")
                ),
            ];
            if !query.is_empty() {
                parts.push(format!("q={}", enc(&query)));
            }
            api_request(
                run,
                auth(ApiCall::new("GET", format!("{DRIVE}?{}", parts.join("&")))),
            )
        }
        "upload" => drive_upload(run, index),
        "download" => {
            let id = required(run, "fileId", index, "file ID")?;
            let request = api_request(
                run,
                auth(ApiCall::new(
                    "GET",
                    format!("{DRIVE}/{}?alt=media", enc(&id)),
                )),
            )?;
            Ok(if run.text("downloadAs", 0)? == "file" {
                with_extra(request, "saveAs", "file".into())
            } else {
                request
            })
        }
        _ => fail(ErrorKind::Node, format!("unknown operation {operation}")),
    }
}

fn drive_items(run: &NodeRun<'_>, body: Val, index: usize) -> Result<Vec<Item>> {
    Ok(match run.text("operation", 0)?.as_str() {
        "list" => match &body {
            Val::Obj(o) => match get_key(o, "files") {
                Val::Arr(files) => files.iter().filter_map(|f| f.as_obj().cloned()).collect(),
                _ => Vec::new(),
            },
            _ => Vec::new(),
        },
        "download" if run.text("downloadAs", 0)? == "file" => vec![obj([
            ("fileId", Val::Str(run.text("fileId", index)?)),
            (
                "file",
                if matches!(body, Val::Obj(_)) {
                    body
                } else {
                    Val::Null
                },
            ),
        ])],
        "download" => vec![obj([
            ("fileId", Val::Str(run.text("fileId", index)?)),
            ("content", body),
        ])],
        _ => as_items(body),
    })
}

fn run_drive(run: &NodeRun<'_>) -> Result<NodeResult> {
    per_item(run, |i| drive(run, i))
}
fn resume_drive(run: &NodeRun<'_>, result: &Obj) -> Result<Vec<Vec<Item>>> {
    api_resume(result, "Google Drive", |body, i| drive_items(run, body, i))
}

const GOOGLE: ParamSpec = credential_param(&["google"]);

pub static GOOGLE_NODES: &[NodeSpec] = &[
    NodeSpec {
        type_name: "google.sheets",
        label: "Google Sheets",
        group: NodeGroup::Productivity,
        description: "Reads rows from a sheet, or appends one row per item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            GOOGLE,
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("read"),
            )
            .options(&["read", "append"]),
            ParamSpec::new(
                "spreadsheetId",
                "Spreadsheet ID",
                ParamKind::Text,
                Default::Text(""),
            )
            .hint("from the sheet’s URL"),
            ParamSpec::new(
                "range",
                "Sheet or range",
                ParamKind::Text,
                Default::Text("Sheet1"),
            ),
            ParamSpec::new(
                "values",
                "Row values (append)",
                ParamKind::Json,
                Default::Text("{{ $json }}"),
            ),
        ],
        run: sheets,
        resume: Some(resume_sheets),
        step: None,
    },
    NodeSpec {
        type_name: "google.gmail",
        label: "Gmail",
        group: NodeGroup::Productivity,
        description: "Sends an email from your Gmail account, one per item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            GOOGLE,
            ParamSpec::new("to", "To", ParamKind::Text, Default::Text("")),
            ParamSpec::new("subject", "Subject", ParamKind::Text, Default::Text("")),
            ParamSpec::new("body", "Message", ParamKind::Text, Default::Text("")),
        ],
        run: run_gmail,
        resume: Some(resume_gmail),
        step: None,
    },
    NodeSpec {
        type_name: "google.calendar",
        label: "Google Calendar",
        group: NodeGroup::Productivity,
        description: "Creates a calendar event per item.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            GOOGLE,
            ParamSpec::new(
                "calendarId",
                "Calendar",
                ParamKind::Text,
                Default::Text("primary"),
            ),
            ParamSpec::new("summary", "Title", ParamKind::Text, Default::Text("")),
            ParamSpec::new("start", "Starts", ParamKind::Text, Default::Text(""))
                .hint("2026-11-22T09:00:00+08:00"),
            ParamSpec::new("end", "Ends", ParamKind::Text, Default::Text("")),
            ParamSpec::new(
                "description",
                "Description",
                ParamKind::Text,
                Default::Text(""),
            ),
        ],
        run: run_calendar,
        resume: Some(resume_calendar),
        step: None,
    },
    NodeSpec {
        type_name: "google.drive",
        label: "Google Drive",
        group: NodeGroup::Productivity,
        description: "Lists files, uploads a file per item (any type, or text), or downloads one as text or a file.",
        inputs: 1,
        outputs: Some(&["main"]),
        params: &[
            GOOGLE,
            ParamSpec::new(
                "operation",
                "Operation",
                ParamKind::Select,
                Default::Text("list"),
            )
            .options(DRIVE_OPERATIONS),
            ParamSpec::new("query", "Search (list)", ParamKind::Text, Default::Text(""))
                .hint("Drive query, e.g. name contains 'report'"),
            ParamSpec::new("file", "File to upload", ParamKind::Text, Default::Text(""))
                .hint("e.g. {{ $json.file.path }}; empty = upload Content as text"),
            ParamSpec::new(
                "name",
                "File name (upload)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "content",
                "Content (upload)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "mimeType",
                "Type (upload)",
                ParamKind::Text,
                Default::Text("text/plain"),
            ),
            ParamSpec::new(
                "folderId",
                "Folder ID (upload)",
                ParamKind::Text,
                Default::Text(""),
            )
            .hint("empty = My Drive"),
            ParamSpec::new(
                "fileId",
                "File ID (download)",
                ParamKind::Text,
                Default::Text(""),
            ),
            ParamSpec::new(
                "downloadAs",
                "Download as",
                ParamKind::Select,
                Default::Text("text"),
            )
            .options(&["text", "file"]),
        ],
        run: run_drive,
        resume: Some(resume_drive),
        step: None,
    },
];
