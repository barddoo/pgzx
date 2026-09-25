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

-- The string check hook rejects an empty value with a custom message and hint.
SET guc.sample_string = '';
SELECT guc_string();

-- guc_get reads any setting through pgzx.guc.getOption.
SELECT guc_get('guc.sample_enum');
SELECT guc_get('work_mem') IS NOT NULL AS has_work_mem;
SELECT guc_get('guc.no_such_setting');

-- The "guc" prefix is reserved: unknown guc.* names are rejected.
SET guc.no_such_setting = 1;
