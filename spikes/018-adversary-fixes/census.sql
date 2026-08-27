SELECT 'tables' k, count(*) v FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'
UNION ALL SELECT 'views', count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='v'
UNION ALL SELECT 'indexes', count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='i'
UNION ALL SELECT 'fks', count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='f'
UNION ALL SELECT 'checks', count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='c'
UNION ALL SELECT 'unique_con', count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='u'
UNION ALL SELECT 'pk_con', count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='p'
UNION ALL SELECT 'exclusion', count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='x'
UNION ALL SELECT 'triggers(row/stmt)', count(*) FROM pg_trigger WHERE NOT tgisinternal
UNION ALL SELECT 'event_triggers', count(*) FROM pg_event_trigger
UNION ALL SELECT 'functions', count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
UNION ALL SELECT 'policies', count(*) FROM pg_policy
UNION ALL SELECT 'roles(openledger*)', count(*) FROM pg_roles WHERE rolname LIKE 'openledger%'
ORDER BY 1;
