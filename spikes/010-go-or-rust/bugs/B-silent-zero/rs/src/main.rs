use anyhow::Result;

const TENANT: &str = "t1";
const COMPANY: &str = "bugco";
const AUTH_AMOUNT: i64 = 20_000;

#[derive(Debug, Default, sqlx::FromRow)]
struct AuthInputs {
    limit_minor: i64,
    posted_minor: i64,
    held_minor: i64,
}

// The same struct, but opting IN to Go's Lax behaviour, which sqlx makes explicit.
#[derive(Debug, Default, sqlx::FromRow)]
struct AuthInputsLax {
    limit_minor: i64,
    #[sqlx(default)]
    posted_minor: i64,
    held_minor: i64,
}

fn decide(limit: i64, posted: i64, held: i64) -> (bool, i64) {
    let available = limit - posted - held;
    (available >= AUTH_AMOUNT, available)
}

// v2 of the query, after the refactor. posted_minor is GONE from the SELECT list.
const Q_DROPPED: &str = r#"
  SELECT cl.limit_minor,
         COALESCE((SELECT SUM(held_minor) FROM card_hold_groups
                    WHERE tenant_id=cl.tenant_id AND company_id=cl.company_id), 0)::bigint AS held_minor
    FROM credit_lines cl WHERE cl.tenant_id=$1 AND cl.company_id=$2"#;

#[tokio::main]
async fn main() -> Result<()> {
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    println!("truth: limit=100000 posted=95000 held=0 -> available=5000, a 20000 auth MUST decline\n");

    // R-B1b: runtime FromRow, column dropped, no opt-in default
    let r = sqlx::query_as::<_, AuthInputs>(Q_DROPPED).bind(TENANT).bind(COMPANY).fetch_one(&pool).await;
    match r {
        Ok(v) => println!("R-B1b query_as / dropped column  -> Ok({v:?})   <-- would be the bug"),
        Err(e) => println!("R-B1b query_as / dropped column  -> Err: {e}"),
    }

    // R-B1c: the SAME thing with #[sqlx(default)] -- Lax, but written down at the field
    let r = sqlx::query_as::<_, AuthInputsLax>(Q_DROPPED).bind(TENANT).bind(COMPANY).fetch_one(&pool).await;
    match r {
        Ok(v) => {
            let (ok, avail) = decide(v.limit_minor, v.posted_minor, v.held_minor);
            println!("R-B1d query_as + #[sqlx(default)] -> Ok({v:?}) approved={ok} available={avail}");
            println!("      (same silent zero as Go's Lax -- but you had to TYPE `#[sqlx(default)]` on the money field)");
        }
        Err(e) => println!("R-B1d -> Err: {e}"),
    }

    // R-B3: the nullable money column. sqlx types it Option<i64>.
    let raw: Option<i64> = sqlx::query_scalar!(
        r#"SELECT raw_amount FROM card_auth_events WHERE tenant_id=$1 AND raw_amount IS NULL LIMIT 1"#,
        TENANT).fetch_one(&pool).await?;
    println!("\nR-B3 raw_amount typed as Option<i64> = {raw:?}");
    println!("R-B3 to use it you must say so: unwrap_or(0) -> {}", raw.unwrap_or(0));
    Ok(())
}
