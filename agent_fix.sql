select "clientName" from agents where "clientName" = 'client1';
select count(*) as before_delete from agents where "clientName" = 'client1';
delete from agents where "clientName" = 'client1';
select count(*) as after_delete from agents where "clientName" = 'client1';