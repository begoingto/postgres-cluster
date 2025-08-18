CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'repl_password';
SELECT pg_create_physical_replication_slot('replica1_slot');
SELECT pg_create_physical_replication_slot('replica2_slot');
