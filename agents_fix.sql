alter table agents alter column "isMaster" set default false;
update agents set "isMaster" = false where "isMaster" is null;