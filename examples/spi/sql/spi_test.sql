CREATE EXTENSION spi;

SET search_path TO spi;

-- Ported from pgrx-examples/spi
SELECT spi_query_random_id() IS NOT NULL AS has_random_id;
SELECT spi_query_title('Hello There!');
SELECT spi_query_title('no such title');
SELECT spi_query_by_id(1);
SELECT spi_query_by_id(42);
SELECT spi_insert_title('pgzx');
SELECT spi_query_title('pgzx');
SELECT issue1209_fixed();

-- Prepared plan, kept for the session
SELECT spi_title_by_id_cached(1);
SELECT spi_title_by_id_cached(3);
SELECT spi_title_by_id_cached(42);

-- Cursor fetching in batches
SELECT spi_cursor_count('SELECT * FROM generate_series(1, 2500)', 1000);
SELECT spi_cursor_count('SELECT * FROM generate_series(1, 2500)');
SELECT spi_cursor_count('SELECT 1 WHERE false', 10);
SELECT spi_cursor_count('SELECT 1', 0);

-- Subtransactions: the empty title violates the CHECK constraint and is
-- skipped, the others are kept
SELECT spi_insert_titles(ARRAY['first', '', 'second']);
SELECT title FROM spi_example WHERE title IN ('first', 'second') ORDER BY title;

-- SECURITY DEFINER with a pinned search_path
SELECT spi_count_titles();
SELECT prosecdef, proconfig FROM pg_proc WHERE proname = 'spi_count_titles';

DROP EXTENSION spi;
