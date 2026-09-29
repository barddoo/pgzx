CREATE EXTENSION file_io;

-- Synchronous roundtrip through a temporary virtual file.
SELECT file_io_roundtrip('hello, world');
SELECT file_io_roundtrip('') = '';
SELECT file_io_roundtrip(repeat('abc', 1000)) = repeat('abc', 1000);

-- Truncate.
SELECT file_io_truncate('0123456789', 4);
SELECT file_io_truncate('0123456789', 0) = '';

-- Out-of-range length is reported as a Postgres error.
SELECT file_io_truncate('abc', 5);
