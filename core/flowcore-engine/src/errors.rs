//! Errors carry a kind and a message and display as `"<Kind>: message"`,
//! the same text the TypeScript reference throws.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    Input,
    Expression,
    Node,
    Cron,
}

impl ErrorKind {
    fn label(self) -> &'static str {
        match self {
            Self::Input => "InputError",
            Self::Expression => "ExpressionError",
            Self::Node => "NodeError",
            Self::Cron => "CronError",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    message: String,
}

impl Error {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    #[must_use]
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.kind.label(), self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// Shorthand for returning an error of `kind`.
pub fn fail<T>(kind: ErrorKind, message: impl Into<String>) -> Result<T> {
    Err(Error::new(kind, message))
}
