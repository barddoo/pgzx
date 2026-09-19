CREATE EXTENSION guc;

SELECT guc_bool();
SELECT guc_int();
SELECT guc_string();
SELECT guc_enum();

SET guc.sample_bool = on;
SELECT guc_bool();

SET guc.sample_int = -5;
SELECT guc_int();

SET guc.sample_int = 500;
SELECT guc_int();

SET guc.sample_string = 'world';
SELECT guc_string();

SET guc.sample_enum = 'large';
SELECT guc_enum();
