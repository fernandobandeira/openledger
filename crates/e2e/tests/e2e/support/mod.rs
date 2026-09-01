//! Helpers only — no `#[test]` lives anywhere under `support/` (the layout
//! rule is stated in main.rs). `postgres` owns where databases come from;
//! `book` owns one test's served book. The re-exports keep the tests writing
//! `support::TestBook`.

mod book;
pub mod postgres;

pub use book::{
    AClose, ASweep, PostAnswer, PostOutcome, TestBook, TestResult, a_report_issued,
    account_balance_path, accounts_path, accounts_reported_by, amount_of_the_line,
    assert_every_member_was_accepted, balance_sheet_path, charge, close_the_period, cursor_path,
    header, pinned_cursor_of, post_a_charge_dated, post_a_pending_hold, refusal_detail,
    refusal_type, row_of_the_account, transaction_path, trial_balance_path,
};
