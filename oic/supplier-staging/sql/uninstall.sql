-- Removes all supplier staging objects (DATA IS LOST).
DROP VIEW xx_supplier_work_v;
DROP VIEW xx_supplier_stg_contact_v;
DROP VIEW xx_supplier_stg_v;
DROP PACKAGE xx_supplier_stg_pkg;
DROP TABLE xx_supplier_stg_log PURGE;
DROP TABLE xx_supplier_stg_contact PURGE;
DROP TABLE xx_supplier_stg PURGE;
