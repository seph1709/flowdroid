use crate::value::{Obj, Val};

/// The variables an expression can read: a shared base object, optionally
/// overlaid with the current item (`$json`) and its position (`$index`).
pub struct Scope<'a> {
    base: &'a Obj,
    json: Option<Val>,
    index: Option<Val>,
}

impl<'a> Scope<'a> {
    #[must_use]
    pub fn new(base: &'a Obj) -> Self {
        Self {
            base,
            json: None,
            index: None,
        }
    }

    #[must_use]
    pub fn with_item(base: &'a Obj, item: &Obj, index: usize) -> Self {
        Self {
            base,
            json: Some(Val::Obj(item.clone())),
            index: Some(Val::from(index)),
        }
    }

    #[must_use]
    pub fn get(&self, name: &str) -> Option<&Val> {
        match name {
            "$json" if self.json.is_some() => self.json.as_ref(),
            "$index" if self.index.is_some() => self.index.as_ref(),
            _ => self.base.get(name),
        }
    }

    #[must_use]
    pub fn has(&self, name: &str) -> bool {
        self.get(name).is_some()
    }
}
