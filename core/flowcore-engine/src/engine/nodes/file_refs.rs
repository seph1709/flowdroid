//! Files between steps travel as references (`{ path, name, mimeType, size }`),
//! never as bytes; see `file_refs.ts`.

use super::spec::NodeRun;
use crate::errors::Result;
use crate::value::{Val, get_key};

const TYPES: &[(&str, &str)] = &[
    ("jpg", "image/jpeg"),
    ("jpeg", "image/jpeg"),
    ("png", "image/png"),
    ("gif", "image/gif"),
    ("webp", "image/webp"),
    ("heic", "image/heic"),
    ("pdf", "application/pdf"),
    ("txt", "text/plain"),
    ("md", "text/markdown"),
    ("csv", "text/csv"),
    ("json", "application/json"),
    ("html", "text/html"),
    ("htm", "text/html"),
    ("xml", "application/xml"),
    ("mp3", "audio/mpeg"),
    ("m4a", "audio/mp4"),
    ("wav", "audio/wav"),
    ("ogg", "audio/ogg"),
    ("mp4", "video/mp4"),
    ("zip", "application/zip"),
    (
        "docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ),
];

/// The media type for a file name, from its extension.
pub fn mime_from_path(path: &str) -> &'static str {
    let ext = path
        .rfind('.')
        .map_or(String::new(), |i| path[i + 1..].to_lowercase());
    TYPES
        .iter()
        .find(|(e, _)| *e == ext)
        .map_or("application/octet-stream", |(_, m)| m)
}

pub fn is_image_path(path: &str) -> bool {
    mime_from_path(path).starts_with("image/")
}

fn path_of(v: &Val) -> String {
    match v {
        Val::Str(s) => s.trim().to_string(),
        Val::Obj(o) => match get_key(o, "path") {
            Val::Str(p) => p.trim().to_string(),
            _ => String::new(),
        },
        _ => String::new(),
    }
}

/// File paths from a parameter: a path, several separated by commas or new
/// lines, a file reference, or a list of either.
pub fn file_paths(run: &NodeRun<'_>, key: &str, index: usize) -> Result<Vec<String>> {
    let v = run.value(key, index)?;
    let parts: Vec<String> = match &v {
        Val::Arr(items) => items.iter().map(path_of).collect(),
        Val::Str(s) => s.split([',', '\n']).map(|p| p.trim().to_string()).collect(),
        other => vec![path_of(other)],
    };
    Ok(parts.into_iter().filter(|p| !p.is_empty()).collect())
}

/// The first file path of a parameter, or "".
pub fn file_path(run: &NodeRun<'_>, key: &str, index: usize) -> Result<String> {
    Ok(file_paths(run, key, index)?
        .into_iter()
        .next()
        .unwrap_or_default())
}

/// Where the host puts a file's bytes, base64-encoded, before sending a request.
pub fn file_marker(path: &str) -> String {
    format!("@@flowdroid-file-base64:{path}@@")
}
