-- Run as the schema owner, e.g. in SQL Developer / SQLcl / Database Actions:  @install.sql
WHENEVER SQLERROR EXIT FAILURE
@@01_tables.sql
@@02_pkg_spec.sql
@@03_pkg_body.sql
@@04_views.sql
SHOW ERRORS PACKAGE BODY xx_supplier_stg_pkg
SELECT object_name, object_type, status FROM user_objects WHERE object_name LIKE 'XX_SUPPLIER%' ORDER BY object_type, object_name;
