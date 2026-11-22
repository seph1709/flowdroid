use crate::value::Val;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
    Not,
    Neg,
}

/// Operators that may skip evaluating their right side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogicalOp {
    Nullish,
    Or,
    And,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Add,
    Sub,
    Mul,
    Div,
    Rem,
}

/// A parsed infix operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Infix {
    Logical(LogicalOp),
    Binary(BinaryOp),
}

impl Infix {
    /// Maps operator text to its operator; `==`/`===` (and `!=`/`!==`) are the same.
    #[must_use]
    pub fn from_text(text: &str) -> Option<Self> {
        let logical = match text {
            "??" => Some(LogicalOp::Nullish),
            "||" => Some(LogicalOp::Or),
            "&&" => Some(LogicalOp::And),
            _ => None,
        };
        if let Some(op) = logical {
            return Some(Self::Logical(op));
        }
        Some(Self::Binary(match text {
            "==" | "===" => BinaryOp::Eq,
            "!=" | "!==" => BinaryOp::Ne,
            "<" => BinaryOp::Lt,
            "<=" => BinaryOp::Le,
            ">" => BinaryOp::Gt,
            ">=" => BinaryOp::Ge,
            "+" => BinaryOp::Add,
            "-" => BinaryOp::Sub,
            "*" => BinaryOp::Mul,
            "/" => BinaryOp::Div,
            "%" => BinaryOp::Rem,
            _ => return None,
        }))
    }
}

#[derive(Debug, Clone)]
pub enum Expr {
    Literal(Val),
    Ident(String),
    Array(Vec<Expr>),
    Member {
        object: Box<Expr>,
        property: Box<Expr>,
    },
    Call {
        callee: Box<Expr>,
        args: Vec<Expr>,
    },
    Unary {
        op: UnaryOp,
        operand: Box<Expr>,
    },
    Logical {
        op: LogicalOp,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    Binary {
        op: BinaryOp,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    Conditional {
        test: Box<Expr>,
        then: Box<Expr>,
        otherwise: Box<Expr>,
    },
}
