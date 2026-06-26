select column_name, data_type from information_schema.columns where table_name = 'agents' order by ordinal_position;
select indexname, indexdef from pg_indexes where tablename = 'agents' order by indexname;
select "clientName", "clientUserId", "ownerUserId" from agents order by "updatedAt" desc limit 20;