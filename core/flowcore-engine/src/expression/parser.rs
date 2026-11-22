//! Recursive-descent parser; the grammar is documented in `engine-ts/src/expression/parser.ts`.

use super::ast::{Expr, Infix, UnaryOp};
use super::lexer::{Token, tokenize};
use crate::errors::{ErrorKind, Result, fail};
use crate::value::Val;

/// Nesting limit, so recursion stays bounded.
pub const MAX_NESTING: usize = 64;

const BINARY_LEVELS: [&[&str]; 7] = [
    &["??"],
    &["||"],
    &["&&"],
    &["==", "!=", "===", "!=="],
    &["<", "<=", ">", ">="],
    &["+", "-"],
    &["*", "/", "%"],
];

pub fn parse_expression(src: &str) -> Result<Expr> {
    let mut parser = Parser {
        tokens: tokenize(src)?,
        pos: 0,
        depth: 0,
    };
    if parser.peek() == &Token::End {
        return fail(ErrorKind::Expression, "empty expression");
    }
    let expr = parser.conditional()?;
    if parser.peek() != &Token::End {
        return parser.unexpected();
    }
    Ok(expr)
}

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    depth: usize,
}

impl Parser {
    fn peek(&self) -> &Token {
        self.tokens
            .get(self.pos)
            .or(self.tokens.last())
            .unwrap_or(&Token::End)
    }

    fn unexpected<T>(&self) -> Result<T> {
        let message = match self.peek() {
            Token::End => "unexpected end of expression".to_owned(),
            Token::Str(_) => "unexpected string".to_owned(),
            Token::Num(_) => "unexpected number".to_owned(),
            Token::Ident(text) => format!("unexpected '{text}'"),
            Token::Op(text) => format!("unexpected '{text}'"),
        };
        fail(ErrorKind::Expression, message)
    }

    fn conditional(&mut self) -> Result<Expr> {
        self.enter()?;
        let test = self.binary(0)?;
        let result = if self.accept_op("?") {
            let then = self.conditional()?;
            self.expect_op(":")?;
            let otherwise = self.conditional()?;
            Expr::Conditional {
                test: Box::new(test),
                then: Box::new(then),
                otherwise: Box::new(otherwise),
            }
        } else {
            test
        };
        self.depth -= 1;
        Ok(result)
    }

    fn binary(&mut self, level: usize) -> Result<Expr> {
        let Some(ops) = BINARY_LEVELS.get(level) else {
            return self.unary();
        };
        let mut left = self.binary(level + 1)?;
        loop {
            let op = match self.peek() {
                Token::Op(text) if ops.contains(text) => Infix::from_text(text),
                _ => None,
            };
            let Some(op) = op else { return Ok(left) };
            self.pos += 1;
            let right = self.binary(level + 1)?;
            let (left_box, right_box) = (Box::new(left), Box::new(right));
            left = match op {
                Infix::Logical(op) => Expr::Logical {
                    op,
                    left: left_box,
                    right: right_box,
                },
                Infix::Binary(op) => Expr::Binary {
                    op,
                    left: left_box,
                    right: right_box,
                },
            };
        }
    }

    fn unary(&mut self) -> Result<Expr> {
        let op = match self.peek() {
            Token::Op("!") => UnaryOp::Not,
            Token::Op("-") => UnaryOp::Neg,
            _ => return self.postfix(),
        };
        self.pos += 1;
        self.enter()?;
        let operand = self.unary()?;
        self.depth -= 1;
        Ok(Expr::Unary {
            op,
            operand: Box::new(operand),
        })
    }

    fn postfix(&mut self) -> Result<Expr> {
        let mut expr = self.primary()?;
        loop {
            if self.accept_op(".") {
                let Token::Ident(name) = self.peek().clone() else {
                    return self.unexpected();
                };
                self.pos += 1;
                expr = member(expr, Expr::Literal(Val::Str(name)));
            } else if self.accept_op("[") {
                let property = self.conditional()?;
                self.expect_op("]")?;
                expr = member(expr, property);
            } else if self.accept_op("(") {
                let args = self.list(")")?;
                expr = Expr::Call {
                    callee: Box::new(expr),
                    args,
                };
            } else {
                return Ok(expr);
            }
        }
    }

    fn primary(&mut self) -> Result<Expr> {
        let token = self.peek().clone();
        self.pos += 1;
        match token {
            Token::Num(n) => return Ok(Expr::Literal(Val::Num(n))),
            Token::Str(s) => return Ok(Expr::Literal(Val::Str(s))),
            Token::Ident(name) => {
                return Ok(match name.as_str() {
                    "true" => Expr::Literal(Val::Bool(true)),
                    "false" => Expr::Literal(Val::Bool(false)),
                    "null" | "undefined" => Expr::Literal(Val::Null),
                    _ => Expr::Ident(name),
                });
            }
            Token::Op("(") => {
                let inner = self.conditional()?;
                self.expect_op(")")?;
                return Ok(inner);
            }
            Token::Op("[") => return Ok(Expr::Array(self.list("]")?)),
            Token::Op(_) | Token::End => {}
        }
        self.pos -= 1;
        self.unexpected()
    }

    /// Comma-separated expressions up to `close`; the opener is already consumed.
    fn list(&mut self, close: &str) -> Result<Vec<Expr>> {
        let mut items = Vec::new();
        if self.accept_op(close) {
            return Ok(items);
        }
        loop {
            items.push(self.conditional()?);
            if !self.accept_op(",") {
                break;
            }
        }
        self.expect_op(close)?;
        Ok(items)
    }

    fn enter(&mut self) -> Result<()> {
        self.depth += 1;
        if self.depth > MAX_NESTING {
            return fail(ErrorKind::Expression, "expression is nested too deeply");
        }
        Ok(())
    }

    fn accept_op(&mut self, text: &str) -> bool {
        if matches!(self.peek(), Token::Op(op) if *op == text) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect_op(&mut self, text: &str) -> Result<()> {
        if self.accept_op(text) {
            Ok(())
        } else {
            self.unexpected()
        }
    }
}

fn member(object: Expr, property: Expr) -> Expr {
    Expr::Member {
        object: Box::new(object),
        property: Box::new(property),
    }
}
