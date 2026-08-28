"""D9 helper: put back the explicit `.response_with::<200, ...>` that
aide-api/src/main.rs deliberately leaves out, so the collision can be observed."""
import sys

p = sys.argv[1]
s = open(p).read()
head = "        .summary(\"Read one account's balance.\")"
i = s.index(head)
j = s.index("}", s.index("// The description below", i))
patched = (
    head
    + "\n        .response_with::<200, Json<AccountBalance>, _>"
    + "(|r| r.description(\"The account's balance.\"))\n"
)
open(p, "w").write(s[:i] + patched + s[j:])
