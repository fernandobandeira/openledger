//! Helpers only — no `#[test]` lives anywhere under `support/` (the layout
//! rule is stated in main.rs). `postgres` owns where databases come from;
//! `book` owns one test's served book. The re-exports keep the tests writing
//! `support::TestBook`.

mod book;
pub mod postgres;

pub use book::{
    PostAnswer, TestBook, TestResult, assert_every_member_was_accepted, charge, header,
};
