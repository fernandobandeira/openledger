//! Helpers only — no `#[test]` lives anywhere under `support/` (the layout
//! rule is stated in main.rs). `postgres` owns where databases come from;
//! `book` owns one test's served book. The re-exports keep the tests writing
//! `support::TestBook`.

mod book;
pub mod postgres;

pub use book::{TestBook, TestResult, header};
