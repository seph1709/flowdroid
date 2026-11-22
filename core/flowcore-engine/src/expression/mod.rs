//! The `{{ }}` expression language: a safe subset of JavaScript expressions.

mod ast;
mod builtins;
mod evaluate;
mod lexer;
mod parser;
mod scope;
mod template;

pub use scope::Scope;
pub use template::{check_templates, is_template, render, render_template};
