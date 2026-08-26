#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "auth_event_kind", rename_all = "snake_case")]
pub enum AuthEventKind {
    Authorization, Incremental, Advice, Reversal, Clearing, Expiry, ExpiryReversal,
    // financial_authorization exists in the DB and is NOT here
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let known: AuthEventKind = sqlx::query_scalar(
        r#"SELECT 'clearing'::auth_event_kind"#).fetch_one(&pool).await?;
    println!("rs  known variant decodes -> {known:?}");

    let r: Result<AuthEventKind, _> = sqlx::query_scalar(
        r#"SELECT 'financial_authorization'::auth_event_kind"#).fetch_one(&pool).await;
    match r {
        Ok(v)  => println!("rs  UNKNOWN variant decoded SILENTLY as {v:?}   <-- would be the bug"),
        Err(e) => println!("rs  UNKNOWN variant REFUSED at decode: {e}"),
    }
    Ok(())
}
