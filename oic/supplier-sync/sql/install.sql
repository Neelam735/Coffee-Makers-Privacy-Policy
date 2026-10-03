-- Run as the schema owner (Database Actions SQL worksheet, SQL Developer or SQLcl):  @install.sql
@@01_tables.sql
@@02_pkg_spec.sql
@@03_pkg_body.sql
@@04_views.sql
SHOW ERRORS PACKAGE BODY xx_sup_pkg
SELECT object_type, COUNT(*) AS objects, SUM(CASE WHEN status = 'VALID' THEN 1 ELSE 0 END) AS valid
  FROM user_objects WHERE object_name LIKE 'XX_SUP%' GROUP BY object_type ORDER BY object_type;
