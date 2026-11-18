CREATE EXTENSION triggers;

SET search_path TO triggers;

-- INSERT: name should be upper-cased by the trigger
INSERT INTO products (name) VALUES ('widget') RETURNING id, name;
INSERT INTO products (name) VALUES ('Gadget') RETURNING id, name;

-- UPDATE: name should be upper-cased on the new value
UPDATE products SET name = 'super widget' WHERE name = 'WIDGET' RETURNING id, name;

-- Verify final state
SELECT name FROM products ORDER BY id;

DROP EXTENSION triggers;
