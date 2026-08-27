// Tell cargo that a change in `migrations/` invalidates the build.
//
// `sqlx::migrate!()` is a proc macro: it reads the migration directory at COMPILE
// time and bakes the files into the binary. Cargo tracks source files, not
// directories a macro happened to read — so without this, adding a NEW migration
// does not invalidate anything. The macro is not re-expanded, the new file is not
// compiled in, and `openledger migrate` reports "schema up to date" and exits 0
// having applied nothing.
//
// Editing an existing migration DOES trigger a rebuild, which is why this
// survives casual testing and fails on the one path that matters: shipping a
// migration someone just wrote.
fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
